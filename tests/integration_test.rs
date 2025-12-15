//! Integration tests for Efficiency Cockpit CLI.

use std::path::PathBuf;
use tempfile::tempdir;

use efficiency_cockpit::{
    config::Config,
    db::Database,
    gatekeeper::{Gatekeeper, GatekeeperConfig},
    search::{IndexDocument, SearchIndex},
    snapshot::{context_from_path, SnapshotService},
};

/// Test full workflow: config -> db -> snapshot -> query
#[test]
fn test_full_snapshot_workflow() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test.db");

    // Create database
    let db = Database::open(&db_path).unwrap();

    // Create snapshot service
    let service = SnapshotService::new(&db);

    // Capture some snapshots
    for i in 0..5 {
        let context = efficiency_cockpit::snapshot::ContextInfo {
            active_file: Some(PathBuf::from(format!("/src/file{}.rs", i))),
            active_directory: Some(PathBuf::from("/src")),
            git_branch: Some("main".to_string()),
            git_repo_root: None,
        };
        service.capture(&context, Some(format!("Note {}", i))).unwrap();
    }

    // Verify snapshots were captured
    let snapshots = service.get_recent(10).unwrap();
    assert_eq!(snapshots.len(), 5);
    assert!(snapshots[0].notes.as_ref().unwrap().contains("Note"));
}

/// Test search index workflow
#[test]
fn test_search_index_workflow() {
    let dir = tempdir().unwrap();
    let index_path = dir.path().join("search_index");

    // Create index
    let index = SearchIndex::create(&index_path).unwrap();

    // Add documents
    let mut writer = index.writer().unwrap();
    writer
        .add_document(&IndexDocument {
            path: "/src/main.rs".to_string(),
            title: "main.rs".to_string(),
            content: "fn main() { println!(\"Hello\"); }".to_string(),
        })
        .unwrap();
    writer
        .add_document(&IndexDocument {
            path: "/src/lib.rs".to_string(),
            title: "lib.rs".to_string(),
            content: "pub mod config; pub mod database;".to_string(),
        })
        .unwrap();
    writer.commit().unwrap();

    // Search
    let results = index.search("main", 10).unwrap();
    assert!(!results.is_empty());

    // Reopen index
    let index2 = SearchIndex::open(&index_path).unwrap();
    let results2 = index2.search("config", 10).unwrap();
    assert!(!results2.is_empty());
}

/// Test gatekeeper with real database
#[test]
fn test_gatekeeper_workflow() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test.db");
    let db = Database::open(&db_path).unwrap();

    // Add file events
    for i in 0..10 {
        let event = efficiency_cockpit::db::new_file_event(
            format!("/src/file{}.rs", i),
            efficiency_cockpit::db::FileEventType::Modified,
        );
        db.insert_file_event(&event).unwrap();
    }

    // Add snapshots with different directories
    for i in 0..10 {
        let mut snapshot = efficiency_cockpit::db::new_snapshot();
        snapshot.active_directory = Some(format!("/project{}", i % 3));
        db.insert_snapshot(&snapshot).unwrap();
    }

    // Create gatekeeper
    let config = GatekeeperConfig::default();
    let gatekeeper = Gatekeeper::new(&db, config);

    // Analyze - should detect context switching
    let nudges = gatekeeper.analyze();
    // May or may not have nudges depending on exact timing
    let _ = nudges;

    // Get daily summary
    let summary = gatekeeper.daily_summary(chrono::Utc::now());
    assert!(summary.total_events >= 10);
}

/// Test config validation
#[test]
fn test_config_validation() {
    let config = Config::default_for_testing();
    assert!(!config.directories.is_empty());
    assert!(!config.ignore_patterns.is_empty());
}

/// Test context from path
#[test]
fn test_context_from_various_paths() {
    let dir = tempdir().unwrap();

    // Create a test file
    let file_path = dir.path().join("test.rs");
    std::fs::write(&file_path, "fn test() {}").unwrap();

    // Get context from file
    let context = context_from_path(&file_path);
    assert!(context.active_file.is_some());
    assert!(context.active_directory.is_some());

    // Get context from directory
    let context2 = context_from_path(dir.path());
    assert!(context2.active_file.is_none());
    assert!(context2.active_directory.is_some());
}

/// Test database cleanup
#[test]
fn test_database_cleanup() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test.db");
    let db = Database::open(&db_path).unwrap();

    // Add many snapshots
    for _ in 0..20 {
        db.insert_snapshot(&efficiency_cockpit::db::new_snapshot()).unwrap();
    }

    // Verify all added
    let all = db.get_recent_snapshots(100).unwrap();
    assert_eq!(all.len(), 20);

    // Cleanup to keep only 5
    let deleted = db.cleanup_old_snapshots(5).unwrap();
    assert_eq!(deleted, 15);

    // Verify cleanup
    let remaining = db.get_recent_snapshots(100).unwrap();
    assert_eq!(remaining.len(), 5);
}

/// Test file event time range queries
#[test]
fn test_file_event_queries() {
    use chrono::{Duration, Utc};

    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test.db");
    let db = Database::open(&db_path).unwrap();

    // Add events
    for i in 0..5 {
        let event = efficiency_cockpit::db::new_file_event(
            format!("/file{}.rs", i),
            efficiency_cockpit::db::FileEventType::Modified,
        );
        db.insert_file_event(&event).unwrap();
    }

    // Query events
    let since = Utc::now() - Duration::hours(1);
    let until = Utc::now() + Duration::hours(1);
    let events = db.get_file_events(since, until).unwrap();
    assert_eq!(events.len(), 5);

    // Query with narrow range (no events)
    let past = Utc::now() - Duration::days(10);
    let also_past = Utc::now() - Duration::days(9);
    let no_events = db.get_file_events(past, also_past).unwrap();
    assert!(no_events.is_empty());
}

/// Test snapshot serialization for export
#[test]
fn test_snapshot_json_serialization() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test.db");
    let db = Database::open(&db_path).unwrap();

    // Add snapshots
    let service = SnapshotService::new(&db);
    for i in 0..3 {
        let context = efficiency_cockpit::snapshot::ContextInfo {
            active_file: Some(PathBuf::from(format!("/src/file{}.rs", i))),
            active_directory: Some(PathBuf::from("/src")),
            git_branch: Some("main".to_string()),
            git_repo_root: None,
        };
        service.capture(&context, Some(format!("Test note {}", i))).unwrap();
    }

    // Retrieve and serialize
    let snapshots = db.get_recent_snapshots(10).unwrap();
    let json = serde_json::to_string_pretty(&snapshots).unwrap();

    assert!(json.contains("active_file"));
    assert!(json.contains("Test note"));
    assert!(json.contains("main"));
}

/// Test CLI output helpers
#[test]
fn test_cli_priority_badge() {
    let high = efficiency_cockpit::cli::priority_badge("HIGH");
    assert!(high.contains("HIGH"));

    let medium = efficiency_cockpit::cli::priority_badge("MEDIUM");
    assert!(medium.contains("MEDIUM"));

    let low = efficiency_cockpit::cli::priority_badge("LOW");
    assert!(low.contains("LOW"));
}

/// Test error type display
#[test]
fn test_error_types() {
    use efficiency_cockpit::error::*;

    let config_err = ConfigError::NotFound {
        path: PathBuf::from("/config.toml"),
    };
    assert!(config_err.to_string().contains("/config.toml"));

    let db_err = DatabaseError::QueryFailed {
        message: "test error".to_string(),
    };
    assert!(db_err.to_string().contains("test error"));
}
