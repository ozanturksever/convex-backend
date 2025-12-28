use common::{
    document::{InternalDocumentId, ResolvedDocument},
    persistence::{
        ConflictStrategy, DocumentLogEntry, Persistence, PersistenceReader, TimestampRange,
    },
    testing::TestPersistence,
    types::{IndexId, TabletId, Timestamp},
    value::{ConvexValue, InternalId},
};
use rusqlite::Connection;
use sqlite::SqlitePersistence;
use std::path::Path;
use tempfile::TempDir;

#[tokio::test]
async fn test_wal_mode_is_enabled() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_wal_enabled.sqlite3")
        .to_str()
        .unwrap();

    let _persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();

    let conn = Connection::open(db_path).unwrap();
    let journal_mode: String = conn
        .query_row("PRAGMA journal_mode;", [], |row| row.get(0))
        .unwrap();

    assert_eq!(journal_mode, "wal");
}

#[tokio::test]
async fn test_wal_mode_creates_wal_files() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_wal_files.sqlite3")
        .to_str()
        .unwrap();

    let persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();

    let tablet_id = TabletId::min();
    let internal_id = InternalId::min();
    let document_id = InternalDocumentId::new(tablet_id, internal_id);
    let value = ConvexValue::try_from(serde_json::json!({"test": "data"})).unwrap();
    let document = ResolvedDocument::from_database(tablet_id, value).unwrap();

    let entries = vec![DocumentLogEntry {
        ts: Timestamp::MIN,
        id: document_id,
        value: Some(document),
        prev_ts: None,
    }];

    persistence.write(&entries, &[], ConflictStrategy::Error).await.unwrap();

    let wal_file_path = db_path.to_string() + "-wal";
    let shm_file_path = db_path.to_string() + "-shm";

    assert!(Path::new(&wal_file_path).exists());
    assert!(Path::new(&shm_file_path).exists());
}

#[tokio::test]
async fn test_wal_mode_synchronous_normal() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_wal_sync.sqlite3")
        .to_str()
        .unwrap();

    let _persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();

    let conn = Connection::open(db_path).unwrap();
    let synchronous_mode: i32 = conn
        .query_row("PRAGMA synchronous;", [], |row| row.get(0))
        .unwrap();

    assert_eq!(synchronous_mode, 1);
}

#[tokio::test]
async fn test_non_wal_mode_synchronous_full() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_non_wal_sync.sqlite3")
        .to_str()
        .unwrap();

    let _persistence = SqlitePersistence::new_with_options(db_path, false).unwrap();

    let conn = Connection::open(db_path).unwrap();
    let synchronous_mode: i32 = conn
        .query_row("PRAGMA synchronous;", [], |row| row.get(0))
        .unwrap();

    assert_eq!(synchronous_mode, 2);
}

#[tokio::test]
async fn test_wal_mode_basic_write_read() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_wal_basic.sqlite3")
        .to_str()
        .unwrap();

    let persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();

    let test_persistence = TestPersistence::new(persistence);

    test_persistence.write_and_read_test().await;
}

#[tokio::test]
async fn test_wal_mode_concurrent_read_during_write() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_wal_concurrent.sqlite3")
        .to_str()
        .unwrap();

    let persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();
    let reader = persistence.reader();

    let tablet_id = TabletId::min();
    let internal_id = InternalId::min();
    let document_id = InternalDocumentId::new(tablet_id, internal_id);
    let value = ConvexValue::try_from(serde_json::json!({"version": 1})).unwrap();
    let document = ResolvedDocument::from_database(tablet_id, value).unwrap();

    let entries = vec![DocumentLogEntry {
        ts: Timestamp::MIN,
        id: document_id,
        value: Some(document),
        prev_ts: None,
    }];

    persistence.write(&entries, &[], ConflictStrategy::Error).await.unwrap();

    let range = TimestampRange::new(Timestamp::MIN, Timestamp::MAX).unwrap();
    let mut document_stream = reader.load_documents(range.clone(), common::query::Order::Asc, 100, Arc::new(()));

    let mut documents = Vec::new();
    while let Some(result) = document_stream.next().await {
        documents.push(result.unwrap());
    }

    assert_eq!(documents.len(), 1);

    let internal_id_2 = InternalId::try_from(vec![1u8; 16]).unwrap();
    let document_id_2 = InternalDocumentId::new(tablet_id, internal_id_2);
    let value_2 = ConvexValue::try_from(serde_json::json!({"version": 2})).unwrap();
    let document_2 = ResolvedDocument::from_database(tablet_id, value_2).unwrap();

    let entries_2 = vec![DocumentLogEntry {
        ts: Timestamp::MIN,
        id: document_id_2,
        value: Some(document_2),
        prev_ts: None,
    }];

    persistence
        .write(&entries_2, &[], ConflictStrategy::Error)
        .await
        .unwrap();

    let mut document_stream_2 = reader.load_documents(range, common::query::Order::Asc, 100, Arc::new(()));

    let mut documents_2 = Vec::new();
    while let Some(result) = document_stream_2.next().await {
        documents_2.push(result.unwrap());
    }

    assert_eq!(documents_2.len(), 2);
}

#[tokio::test]
async fn test_wal_mode_checkpoint() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_wal_checkpoint.sqlite3")
        .to_str()
        .unwrap();

    let persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();

    let tablet_id = TabletId::min();
    for i in 0u64..10 {
        let internal_id = InternalId::try_from(i.to_be_bytes().to_vec()).unwrap();
        let document_id = InternalDocumentId::new(tablet_id, internal_id);
        let value = ConvexValue::try_from(serde_json::json!({"data": i})).unwrap();
        let document = ResolvedDocument::from_database(tablet_id, value).unwrap();
        let ts = Timestamp::try_from(i).unwrap();

        let entries = vec![DocumentLogEntry {
            ts,
            id: document_id,
            value: Some(document),
            prev_ts: None,
        }];

        persistence
            .write(&entries, &[], ConflictStrategy::Error)
            .await
            .unwrap();
    }

    let conn = Connection::open(db_path).unwrap();
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE);", []).unwrap();

    let checkpoint_result: (i32, i32, i32) = conn
        .query_row(
            "PRAGMA wal_checkpoint(TRUNCATE);",
            [],
            |row| (row.get(0), row.get(1), row.get(2)),
        )
        .unwrap();

    assert_eq!(checkpoint_result.2, 0);
}

#[tokio::test]
async fn test_wal_mode_persistence_over_restart() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_wal_restart.sqlite3")
        .to_str()
        .unwrap();

    {
        let persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();

        let tablet_id = TabletId::min();
        let internal_id = InternalId::min();
        let document_id = InternalDocumentId::new(tablet_id, internal_id);
        let value = ConvexValue::try_from(serde_json::json!({"persisted": true})).unwrap();
        let document = ResolvedDocument::from_database(tablet_id, value).unwrap();

        let entries = vec![DocumentLogEntry {
            ts: Timestamp::MIN,
            id: document_id,
            value: Some(document),
            prev_ts: None,
        }];

        persistence.write(&entries, &[], ConflictStrategy::Error).await.unwrap();
    }

    {
        let persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();
        let reader = persistence.reader();

        let range = TimestampRange::new(Timestamp::MIN, Timestamp::MAX).unwrap();
        let mut document_stream = reader.load_documents(range, common::query::Order::Asc, 100, Arc::new(()));

        let mut documents = Vec::new();
        while let Some(result) = document_stream.next().await {
            documents.push(result.unwrap());
        }

        assert_eq!(documents.len(), 1);
        assert_eq!(documents[0].ts, Timestamp::MIN);
    }
}

#[tokio::test]
async fn test_wal_mode_with_indices() {
    let db = TempDir::new().unwrap();
    let db_path = db
        .path()
        .join("test_wal_indices.sqlite3")
        .to_str()
        .unwrap();

    let persistence = SqlitePersistence::new_with_options(db_path, true).unwrap();
    let reader = persistence.reader();

    let tablet_id = TabletId::min();
    let index_id = IndexId::min();

    let mut documents = Vec::new();
    let mut indexes = Vec::new();

    for i in 0u8..5 {
        let internal_id = InternalId::try_from(vec![i; 16]).unwrap();
        let document_id = InternalDocumentId::new(tablet_id, internal_id);
        let value = ConvexValue::try_from(serde_json::json!({"id": i})).unwrap();
        let document = ResolvedDocument::from_database(tablet_id, value).unwrap();
        let ts = Timestamp::try_from(i as u64).unwrap();

        documents.push(DocumentLogEntry {
            ts,
            id: document_id,
            value: Some(document),
            prev_ts: None,
        });

        let index_key = vec![i];
        indexes.push(common::persistence::PersistenceIndexEntry {
            index_id,
            key_prefix: index_key.clone(),
            key_suffix: None,
            key_sha256: index_key,
            ts,
            value: Some(document_id),
            deleted: false,
        });
    }

    persistence
        .write(&documents, &indexes, ConflictStrategy::Error)
        .await
        .unwrap();

    let interval = common::interval::Interval::all();
    let mut index_stream = reader.index_scan(
        index_id,
        tablet_id,
        Timestamp::MAX,
        &interval,
        common::query::Order::Asc,
        100,
        Arc::new(()),
    );

    let mut index_entries = Vec::new();
    while let Some(result) = index_stream.next().await {
        index_entries.push(result.unwrap());
    }

    assert_eq!(index_entries.len(), 5);
}
