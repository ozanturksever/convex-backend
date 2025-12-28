#!/bin/bash
set -euo pipefail

# =============================================================================
# Hetzner Cloud Build Script for Convex Backend
# =============================================================================
# This script:
# 1. Creates/uses an SSH key in hcloud
# 2. Spins up a powerful build machine (using cached snapshot if available)
# 3. Clones the repo and builds the project
# 4. Downloads the build artifacts
# 5. Cleans up the server
#
# Snapshot caching:
# - Use --create-snapshot to create/update build environment snapshots
# - Use --list-snapshots to list existing snapshots
# - Use --delete-snapshots to delete all build snapshots
# - Set USE_SNAPSHOT=false to force fresh builds without snapshots
# =============================================================================

# Configuration
SERVER_NAME_PREFIX="convex-build-$(date +%s)"
IMAGE="${IMAGE:-ubuntu-24.04}"
LOCATION="${LOCATION:-nbg1}"  # Nuremberg datacenter
LOCATION_ARM="${LOCATION_ARM:-nbg1}"  # Nuremberg datacenter (ARM servers available here too)
SSH_KEY_NAME="${SSH_KEY_NAME:-convex-build-key}"
REPO_URL="${REPO_URL:-git@github.com:ozanturksever/convex-backend.git}"
BRANCH="${BRANCH:-main}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
ARTIFACT_DIR="${ARTIFACT_DIR:-./build-artifacts}"

# Target architectures: "amd64", "arm64", or "all" (for both)
TARGET_ARCHS="${TARGET_ARCHS:-all}"

# Parallel build: set to "false" to build sequentially
PARALLEL_BUILD="${PARALLEL_BUILD:-true}"

# Snapshot caching configuration
USE_SNAPSHOT="${USE_SNAPSHOT:-true}"          # Use existing snapshots if available
SNAPSHOT_PREFIX="${SNAPSHOT_PREFIX:-convex-build-env}"  # Prefix for snapshot names

# Server types for each architecture (can be overridden)
SERVER_TYPE_AMD64="${SERVER_TYPE_AMD64:-ccx33}"  # 8 dedicated vCPUs, 32GB RAM (x86_64)
SERVER_TYPE_ARM64="${SERVER_TYPE_ARM64:-cax31}"  # 8 Ampere cores, 16GB RAM (ARM64)

# Arrays to track servers for cleanup
declare -a SERVER_IDS=()
declare -a SERVER_NAMES=()
declare -a BUILT_ARTIFACTS=()

# Associative arrays to track server info per architecture
declare -A SERVER_IPS=()
declare -A BUILD_PIDS=()
declare -A BUILD_LOGS=()
declare -A USING_SNAPSHOT=()  # Track which builds are using snapshots

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Cleanup function
cleanup() {
    local exit_code=$?
    for i in "${!SERVER_IDS[@]}"; do
        local server_id="${SERVER_IDS[$i]}"
        local server_name="${SERVER_NAMES[$i]}"
        if [[ -n "$server_id" ]]; then
            log_info "Cleaning up server ${server_name} (ID: ${server_id})..."
            hcloud server delete "$server_id" --poll-interval 2s || true
            log_success "Server ${server_name} deleted"
        fi
    done
    exit $exit_code
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v hcloud &> /dev/null; then
        log_error "hcloud CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! hcloud context active &> /dev/null; then
        log_error "hcloud is not authenticated. Run 'hcloud context create <name>' first."
        exit 1
    fi
    
    if [[ ! -f ~/.ssh/id_rsa.pub ]] && [[ ! -f ~/.ssh/id_ed25519.pub ]]; then
        log_error "No SSH public key found. Please generate one with 'ssh-keygen'."
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Setup SSH key in hcloud
setup_ssh_key() {
    log_info "Setting up SSH key in hcloud..."
    
    # Check if key already exists
    if hcloud ssh-key describe "$SSH_KEY_NAME" &> /dev/null; then
        log_info "SSH key '$SSH_KEY_NAME' already exists in hcloud"
        return 0
    fi
    
    # Find local SSH public key
    local pubkey_file
    if [[ -f ~/.ssh/id_ed25519.pub ]]; then
        pubkey_file=~/.ssh/id_ed25519.pub
    elif [[ -f ~/.ssh/id_rsa.pub ]]; then
        pubkey_file=~/.ssh/id_rsa.pub
    else
        log_error "No SSH public key found"
        exit 1
    fi
    
    log_info "Uploading SSH key from $pubkey_file..."
    hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$pubkey_file"
    log_success "SSH key uploaded to hcloud"
}

# Get server type for architecture
get_server_type() {
    local arch="$1"
    case "$arch" in
        amd64) echo "$SERVER_TYPE_AMD64" ;;
        arm64) echo "$SERVER_TYPE_ARM64" ;;
        *)     log_error "Unknown architecture: $arch"; exit 1 ;;
    esac
}

# Get location for architecture (ARM servers may not be available in all locations)
get_location() {
    local arch="$1"
    case "$arch" in
        amd64) echo "$LOCATION" ;;
        arm64) echo "$LOCATION_ARM" ;;
        *)     echo "$LOCATION" ;;
    esac
}

# Get snapshot name for architecture
get_snapshot_name() {
    local arch="$1"
    echo "${SNAPSHOT_PREFIX}-${arch}"
}

# Get snapshot ID by looking up the description (since hcloud doesn't support custom names)
get_snapshot_id() {
    local arch="$1"
    local snapshot_name
    snapshot_name=$(get_snapshot_name "$arch")
    
    # Look up snapshot by description (which we set to the snapshot name)
    hcloud image list -o noheader -o columns=id,type,description | \
        grep "snapshot" | \
        grep "$snapshot_name" | \
        awk '{print $1}' | \
        head -1
}

# Check if a snapshot exists for the given architecture
snapshot_exists() {
    local arch="$1"
    local snapshot_id
    snapshot_id=$(get_snapshot_id "$arch")
    
    if [[ -n "$snapshot_id" ]]; then
        return 0
    else
        return 1
    fi
}

# Get the image to use for a given architecture (snapshot if available, otherwise base image)
# Note: This function only returns the image ID/name, logging is done separately
get_image_for_arch() {
    local arch="$1"
    
    if [[ "$USE_SNAPSHOT" == "true" ]]; then
        local snapshot_id
        snapshot_id=$(get_snapshot_id "$arch")
        
        if [[ -n "$snapshot_id" ]]; then
            USING_SNAPSHOT[$arch]="true"
            echo "$snapshot_id"  # Use ID since hcloud doesn't support custom names
            return
        fi
    fi
    
    USING_SNAPSHOT[$arch]="false"
    echo "$IMAGE"
}

# Create a snapshot from a server
create_snapshot_from_server() {
    local arch="$1"
    local server_ip="${SERVER_IPS[$arch]}"
    local server_name
    server_name=$(hcloud server list -o noheader -o columns=name | grep "${SERVER_NAME_PREFIX}-${arch}" | head -1)
    local snapshot_name
    snapshot_name=$(get_snapshot_name "$arch")
    
    log_info "[$arch] Creating snapshot '$snapshot_name' from server..."
    
    # Delete existing snapshot if it exists
    if snapshot_exists "$arch"; then
        log_info "[$arch] Deleting existing snapshot..."
        local old_snapshot_id
        old_snapshot_id=$(get_snapshot_id "$arch")
        hcloud image delete "$old_snapshot_id"
    fi
    
    # Power off the server before creating snapshot (recommended for consistency)
    log_info "[$arch] Powering off server for snapshot..."
    ssh -o StrictHostKeyChecking=no "root@$server_ip" "sync" || true
    hcloud server poweroff "$server_name" --poll-interval 2s
    
    # Create the snapshot
    log_info "[$arch] Creating snapshot (this may take a few minutes)..."
    hcloud server create-image --type snapshot --description "Convex build environment for $arch" --label arch="$arch" "$server_name"
    
    # Rename the snapshot to our standard name
    local new_snapshot_id
    new_snapshot_id=$(hcloud image list -o noheader -o columns=id,description | grep "Convex build environment for $arch" | tail -1 | awk '{print $1}')
    
    if [[ -n "$new_snapshot_id" ]]; then
        # Update the image description to include our name (hcloud doesn't support renaming)
        # We use labels to identify our snapshots
        hcloud image add-label "$new_snapshot_id" "name=$snapshot_name" || true
        hcloud image update "$new_snapshot_id" --description "$snapshot_name"
        log_success "[$arch] Snapshot created: $snapshot_name (ID: $new_snapshot_id)"
    else
        log_error "[$arch] Failed to find created snapshot"
        return 1
    fi
    
    # Power the server back on
    log_info "[$arch] Powering server back on..."
    hcloud server poweron "$server_name" --poll-interval 2s
    
    # Wait for SSH to be ready again
    log_info "[$arch] Waiting for SSH to be ready..."
    local max_attempts=30
    local attempt=0
    while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "root@$server_ip" "echo 'SSH ready'" &> /dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "[$arch] SSH connection timeout after snapshot"
            return 1
        fi
        sleep 5
    done
    log_success "[$arch] Server back online"
}

# List all build snapshots
list_snapshots() {
    log_info "Listing build environment snapshots..."
    echo ""
    echo "Snapshots with prefix '$SNAPSHOT_PREFIX':"
    echo "=========================================="
    
    local found=0
    for arch in amd64 arm64; do
        local snapshot_name
        snapshot_name=$(get_snapshot_name "$arch")
        local snapshot_id
        snapshot_id=$(get_snapshot_id "$arch")
        
        if [[ -n "$snapshot_id" ]]; then
            local created_at size
            created_at=$(hcloud image describe "$snapshot_id" -o format='{{.Created}}')
            size=$(hcloud image describe "$snapshot_id" -o format='{{.ImageSize}}')
            echo "  - $snapshot_name"
            echo "    ID: $snapshot_id"
            echo "    Created: $created_at"
            echo "    Size: ${size}GB"
            echo ""
            found=1
        fi
    done
    
    if [[ $found -eq 0 ]]; then
        echo "  No snapshots found."
        echo ""
        echo "Run with --create-snapshot to create build environment snapshots."
    fi
}

# Delete all build snapshots
delete_snapshots() {
    log_info "Deleting all build environment snapshots..."
    
    for arch in amd64 arm64; do
        local snapshot_name
        snapshot_name=$(get_snapshot_name "$arch")
        local snapshot_id
        snapshot_id=$(get_snapshot_id "$arch")
        
        if [[ -n "$snapshot_id" ]]; then
            log_info "Deleting snapshot: $snapshot_name (ID: $snapshot_id)"
            hcloud image delete "$snapshot_id"
            log_success "Deleted: $snapshot_name"
        else
            log_info "Snapshot not found: $snapshot_name"
        fi
    done
    
    log_success "Snapshot cleanup complete"
}

# Create the build server for a specific architecture
# Stores server IP in SERVER_IPS associative array
create_server() {
    local arch="$1"
    local server_name="${SERVER_NAME_PREFIX}-${arch}"
    local server_type
    server_type=$(get_server_type "$arch")
    local location
    location=$(get_location "$arch")
    local image
    image=$(get_image_for_arch "$arch")
    
    # Log what image we're using
    if [[ "${USING_SNAPSHOT[$arch]:-false}" == "true" ]]; then
        local snapshot_name
        snapshot_name=$(get_snapshot_name "$arch")
        log_info "[$arch] Using cached snapshot: $snapshot_name (ID: $image)"
    else
        log_info "[$arch] Using base image: $image"
    fi
    
    log_info "[$arch] Creating server '$server_name' (type: $server_type, image: $image, location: $location)..."
    
    # Create the server and wait for it to be ready
    if ! hcloud server create \
        --name "$server_name" \
        --type "$server_type" \
        --image "$image" \
        --location "$location" \
        --ssh-key "$SSH_KEY_NAME" \
        --poll-interval 2s; then
        log_error "[$arch] Failed to create server"
        return 1
    fi
    
    # Wait a moment for the server to be fully registered
    sleep 2
    
    local server_id
    local server_ip
    server_id=$(hcloud server describe "$server_name" -o format='{{.ID}}' 2>/dev/null)
    server_ip=$(hcloud server describe "$server_name" -o format='{{.PublicNet.IPv4.IP}}' 2>/dev/null)
    
    if [[ -z "$server_id" ]] || [[ -z "$server_ip" ]]; then
        log_error "[$arch] Failed to get server details after creation"
        return 1
    fi
    
    # Track for cleanup
    SERVER_IDS+=("$server_id")
    SERVER_NAMES+=("$server_name")
    
    # Store IP for this architecture
    SERVER_IPS[$arch]="$server_ip"
    
    log_success "[$arch] Server created: ID=$server_id, IP=$server_ip"
    
    # Wait for SSH to be ready
    log_info "[$arch] Waiting for SSH to be ready..."
    local max_attempts=30
    local attempt=0
    while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "root@$server_ip" "echo 'SSH ready'" &> /dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "[$arch] SSH connection timeout after $max_attempts attempts"
            return 1
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    log_success "[$arch] SSH connection established"
}

# Setup build environment on the server (install dependencies)
# This is skipped when using a cached snapshot
run_setup() {
    local arch="$1"
    local server_ip="${SERVER_IPS[$arch]}"
    
    log_info "[$arch] Setting up build environment..."
    
    # Read .nvmrc for Node version if it exists locally (extract major version only)
    local node_version="20"
    if [[ -f .nvmrc ]]; then
        # Extract just the major version number (e.g., "20" from "20.19.5")
        node_version=$(cat .nvmrc | tr -d '[:space:]' | cut -d'.' -f1)
    fi
    
    # Create the setup script
    local setup_script='#!/bin/bash
set -euxo pipefail

echo "=== Installing system dependencies ==="
apt-get update
apt-get install -y \
    build-essential \
    curl \
    git \
    pkg-config \
    libssl-dev \
    clang \
    llvm \
    cmake \
    protobuf-compiler

echo "=== Installing Node.js '"$node_version"' ==="
curl -fsSL https://deb.nodesource.com/setup_'"$node_version"'.x | bash -
apt-get install -y nodejs
npm install -g pnpm

echo "=== Installing Rust ==="
curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup default stable

echo "=== Installing just ==="
cargo install just

echo "=== Setup complete ==="
rustc --version
node --version
just --version

echo "SETUP_SUCCESS"
'

    # Run the setup script
    log_info "[$arch] Running setup script on server (this may take a while)..."
    echo "$setup_script" | ssh -o StrictHostKeyChecking=no "root@$server_ip" "cat > /tmp/setup.sh && chmod +x /tmp/setup.sh && /tmp/setup.sh"
    
    log_success "[$arch] Setup completed on remote server"
}

# Run the build on the remote server
# Uses SERVER_IPS associative array
run_build() {
    local arch="$1"
    local server_ip="${SERVER_IPS[$arch]}"
    local using_snapshot="${USING_SNAPSHOT[$arch]:-false}"
    
    log_info "[$arch] Starting build on remote server..."
    
    # Create the build script to run on the server
    local build_script='#!/bin/bash
set -euxo pipefail

# Source cargo env (needed for both fresh and snapshot builds)
if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
fi

echo "=== Preparing build directory ==="
# Clean up any previous build
rm -rf /build

echo "=== Cloning repository ==="
# Setup SSH for GitHub
mkdir -p ~/.ssh
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

git clone --depth 1 --branch '"$BRANCH"' '"$REPO_URL"' /build
cd /build

echo "=== Building JavaScript dependencies ==="
# Setup rush dependencies first
cd scripts && npm ci && cd ..
just rush install
just rush build -t system-udfs -t udf-runtime

echo "=== Building Rust project ==="
# Build the local_backend binary
cargo build --profile '"$BUILD_PROFILE"' -p local_backend

echo "=== Build complete ==="
ls -la target/'"$BUILD_PROFILE"'/convex-local-backend || ls -la target/'"$BUILD_PROFILE"'/

echo "BUILD_SUCCESS"
'

    # Copy SSH key for GitHub access (to clone private repo)
    # Note: Using scp is simpler than SSH agent forwarding for one-off builds
    log_info "[$arch] Copying SSH key to server for GitHub access..."
    local ssh_key_file
    if [[ -f ~/.ssh/id_ed25519 ]]; then
        ssh_key_file=~/.ssh/id_ed25519
    else
        ssh_key_file=~/.ssh/id_rsa
    fi
    
    scp -o StrictHostKeyChecking=no "$ssh_key_file" "root@$server_ip:/root/.ssh/id_rsa"
    ssh -o StrictHostKeyChecking=no "root@$server_ip" "chmod 600 /root/.ssh/id_rsa"
    
    # If not using snapshot, run setup first
    if [[ "$using_snapshot" != "true" ]]; then
        run_setup "$arch"
    else
        log_info "[$arch] Using cached snapshot, skipping setup..."
    fi
    
    # Run the build script
    log_info "[$arch] Running build script on server (this may take a while)..."
    echo "$build_script" | ssh -o StrictHostKeyChecking=no "root@$server_ip" "cat > /tmp/build.sh && chmod +x /tmp/build.sh && /tmp/build.sh"
    
    log_success "[$arch] Build completed on remote server"
}

# Download the build artifacts
# Uses SERVER_IPS associative array
download_artifacts() {
    local arch="$1"
    local server_ip="${SERVER_IPS[$arch]}"
    
    log_info "[$arch] Downloading build artifacts..."
    
    mkdir -p "$ARTIFACT_DIR"
    
    # Determine the binary path based on build profile
    local binary_path="target/${BUILD_PROFILE}/convex-local-backend"
    
    # Get OS from the build server and normalize it
    local raw_os
    raw_os=$(ssh -o StrictHostKeyChecking=no "root@$server_ip" "uname -s")
    local os
    case "$raw_os" in
        Linux)  os="linux" ;;
        Darwin) os="darwin" ;;
        *)      os=$(echo "$raw_os" | tr '[:upper:]' '[:lower:]') ;;  # lowercase fallback
    esac
    
    local artifact_name="convex-local-backend-${os}-${arch}"
    
    # Download the binary with architecture in the name
    scp -o StrictHostKeyChecking=no "root@$server_ip:/build/$binary_path" "$ARTIFACT_DIR/$artifact_name"
    
    # Get file info
    local artifact_size
    artifact_size=$(ls -lh "$ARTIFACT_DIR/$artifact_name" | awk '{print $5}')
    
    log_success "[$arch] Artifact downloaded to $ARTIFACT_DIR/$artifact_name (size: $artifact_size)"
    
    # Track built artifacts
    BUILT_ARTIFACTS+=("$artifact_name")
}

# Build for a single architecture (used in sequential mode)
build_for_arch() {
    local arch="$1"
    log_info "========== Building for $arch =========="
    create_server "$arch"
    run_build "$arch"
    download_artifacts "$arch"
    log_success "========== Completed $arch build =========="
}

# Build for a single architecture in background (used in parallel mode)
# Writes output to a log file and creates a marker file on completion
build_for_arch_background() {
    local arch="$1"
    local log_file="$2"
    
    {
        echo "[$arch] ========== Starting build =========="
        if ! run_build "$arch"; then
            echo "[$arch] ========== BUILD FAILED =========="
            exit 1
        fi
        echo "[$arch] ========== Build completed =========="
    } >> "$log_file" 2>&1
}

# Get list of target architectures
get_target_archs() {
    case "$TARGET_ARCHS" in
        all)   echo "amd64 arm64" ;;
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        *)     echo "$TARGET_ARCHS" ;;  # Allow comma-separated custom list
    esac
}

# Stream log files in real-time
stream_logs() {
    local -a log_files=("$@")
    
    # Use tail to follow all log files
    tail -f "${log_files[@]}" 2>/dev/null &
    TAIL_PID=$!
}

# Stop streaming logs
stop_log_streaming() {
    if [[ -n "${TAIL_PID:-}" ]]; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
    fi
}

# Run builds in parallel
run_parallel_builds() {
    local archs=("$@")
    local temp_dir
    temp_dir=$(mktemp -d)
    local -a log_files=()
    local -a pids=()
    local failed=0
    
    log_info "Starting parallel builds for: ${archs[*]}"
    echo ""
    
    # Start builds in background
    for arch in "${archs[@]}"; do
        local log_file="$temp_dir/build-${arch}.log"
        log_files+=("$log_file")
        BUILD_LOGS[$arch]="$log_file"
        
        # Create empty log file
        touch "$log_file"
        
        log_info "[$arch] Starting background build process..."
        build_for_arch_background "$arch" "$log_file" &
        local pid=$!
        pids+=("$pid")
        BUILD_PIDS[$arch]="$pid"
        log_info "[$arch] Build started (PID: $pid, log: $log_file)"
    done
    
    echo ""
    log_info "All builds started. Streaming logs from all builds..."
    log_info "(Press Ctrl+C to cancel all builds)"
    echo ""
    echo "=============================================================================="
    
    # Stream logs from all builds
    stream_logs "${log_files[@]}"
    
    # Wait for all builds to complete
    for i in "${!archs[@]}"; do
        local arch="${archs[$i]}"
        local pid="${pids[$i]}"
        
        if wait "$pid"; then
            log_success "[$arch] Build process completed successfully"
        else
            log_error "[$arch] Build process failed"
            failed=1
        fi
    done
    
    echo "=============================================================================="
    
    # Stop log streaming
    stop_log_streaming
    
    # Check for failures
    if [[ $failed -eq 1 ]]; then
        log_error "One or more builds failed. Check logs above for details."
        echo ""
        echo "Log files:"
        for arch in "${archs[@]}"; do
            echo "  - $arch: ${BUILD_LOGS[$arch]}"
        done
        exit 1
    fi
    
    log_success "All parallel builds completed successfully"
    
    # Cleanup temp dir (logs)
    rm -rf "$temp_dir"
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo -e "${GREEN}BUILD COMPLETE${NC}"
    echo "=============================================="
    echo "Artifact directory: $ARTIFACT_DIR"
    echo "Build profile: $BUILD_PROFILE"
    echo "Branch: $BRANCH"
    echo ""
    echo "Built artifacts:"
    for artifact in "${BUILT_ARTIFACTS[@]}"; do
        local size
        size=$(ls -lh "$ARTIFACT_DIR/$artifact" | awk '{print $5}')
        echo "  - $artifact ($size)"
    done
    echo ""
    echo "Snapshot usage:"
    for arch in "${!USING_SNAPSHOT[@]}"; do
        if [[ "${USING_SNAPSHOT[$arch]}" == "true" ]]; then
            echo "  - $arch: used cached snapshot (fast build)"
        else
            echo "  - $arch: fresh build (no snapshot)"
        fi
    done
    echo "=============================================="
}

# Create snapshots for all target architectures
create_snapshots() {
    local archs_str
    archs_str=$(get_target_archs)
    local -a archs=($archs_str)
    
    log_info "Creating build environment snapshots for: ${archs[*]}"
    echo ""
    
    # Force fresh builds (don't use existing snapshots)
    USE_SNAPSHOT="false"
    
    for arch in "${archs[@]}"; do
        log_info "========== Creating snapshot for $arch =========="
        
        # Create server
        create_server "$arch"
        
        # Run setup only (no build)
        local server_ip="${SERVER_IPS[$arch]}"
        
        # Copy SSH key
        local ssh_key_file
        if [[ -f ~/.ssh/id_ed25519 ]]; then
            ssh_key_file=~/.ssh/id_ed25519
        else
            ssh_key_file=~/.ssh/id_rsa
        fi
        scp -o StrictHostKeyChecking=no "$ssh_key_file" "root@$server_ip:/root/.ssh/id_rsa"
        ssh -o StrictHostKeyChecking=no "root@$server_ip" "chmod 600 /root/.ssh/id_rsa"
        
        # Run setup
        run_setup "$arch"
        
        # Create snapshot
        create_snapshot_from_server "$arch"
        
        log_success "========== Snapshot created for $arch =========="
        echo ""
    done
    
    echo "=============================================="
    echo -e "${GREEN}SNAPSHOTS CREATED${NC}"
    echo "=============================================="
    echo "Created snapshots:"
    for arch in "${archs[@]}"; do
        echo "  - $(get_snapshot_name "$arch")"
    done
    echo ""
    echo "Future builds will use these snapshots automatically."
    echo "Use USE_SNAPSHOT=false to force fresh builds."
    echo "=============================================="
}

# Show usage help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --create-snapshot    Create/update build environment snapshots
  --list-snapshots     List existing build environment snapshots
  --delete-snapshots   Delete all build environment snapshots
  --help, -h           Show this help message

Environment Variables:
  TARGET_ARCHS         Target architectures: "amd64", "arm64", or "all" (default: all)
  PARALLEL_BUILD       Enable parallel builds: "true" or "false" (default: true)
  USE_SNAPSHOT         Use cached snapshots if available (default: true)
  SNAPSHOT_PREFIX      Prefix for snapshot names (default: convex-build-env)
  BUILD_PROFILE        Cargo build profile (default: release)
  BRANCH               Git branch to build (default: main)
  REPO_URL             Git repository URL
  ARTIFACT_DIR         Directory for build artifacts (default: ./build-artifacts)
  SERVER_TYPE_AMD64    Hetzner server type for amd64 (default: ccx33)
  SERVER_TYPE_ARM64    Hetzner server type for arm64 (default: cax31)
  LOCATION             Hetzner location for amd64 builds (default: nbg1)
  LOCATION_ARM         Hetzner location for arm64 builds (default: fsn1)

Examples:
  # First time: create snapshots for faster future builds
  $0 --create-snapshot

  # Normal build (uses snapshots if available)
  $0

  # Build without using snapshots
  USE_SNAPSHOT=false $0

  # Build only for amd64
  TARGET_ARCHS=amd64 $0

  # List existing snapshots
  $0 --list-snapshots
EOF
}

# Main function
main() {
    # Handle command line arguments
    case "${1:-}" in
        --create-snapshot)
            echo "=============================================="
            echo "Creating Build Environment Snapshots"
            echo "=============================================="
            echo ""
            check_prerequisites
            setup_ssh_key
            create_snapshots
            exit 0
            ;;
        --list-snapshots)
            check_prerequisites
            list_snapshots
            exit 0
            ;;
        --delete-snapshots)
            check_prerequisites
            delete_snapshots
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        "")
            # Normal build mode
            ;;
        *)
            log_error "Unknown option: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
    
    echo "=============================================="
    echo "Hetzner Cloud Build Script for Convex Backend"
    echo "=============================================="
    echo ""
    
    local archs_str
    archs_str=$(get_target_archs)
    local -a archs=($archs_str)
    local num_archs=${#archs[@]}
    
    log_info "Target architectures: ${archs[*]}"
    log_info "Parallel build: $PARALLEL_BUILD"
    log_info "Use snapshots: $USE_SNAPSHOT"
    
    check_prerequisites
    setup_ssh_key
    
    # Determine build mode
    if [[ "$PARALLEL_BUILD" == "true" ]] && [[ $num_archs -gt 1 ]]; then
        log_info "Using parallel build mode for $num_archs architectures"
        echo ""
        
        # Phase 1: Create all servers (sequentially - this is fast and avoids subshell issues)
        log_info "Phase 1: Creating servers for all architectures..."
        for arch in "${archs[@]}"; do
            if ! create_server "$arch"; then
                log_error "Failed to create server for $arch"
                exit 1
            fi
        done
        
        log_success "All servers created successfully"
        echo ""
        
        # Phase 2: Run builds in parallel
        log_info "Phase 2: Running builds in parallel..."
        run_parallel_builds "${archs[@]}"
        echo ""
        
        # Phase 3: Download artifacts
        log_info "Phase 3: Downloading artifacts..."
        for arch in "${archs[@]}"; do
            download_artifacts "$arch"
        done
    else
        # Sequential build mode
        if [[ $num_archs -gt 1 ]]; then
            log_info "Using sequential build mode (set PARALLEL_BUILD=true for parallel)"
        fi
        
        for arch in "${archs[@]}"; do
            build_for_arch "$arch"
        done
    fi
    
    print_summary
    
    # Servers will be cleaned up by trap
}

# Run main
main "$@"
