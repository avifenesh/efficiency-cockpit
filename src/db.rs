//! Database layer for the Efficiency Cockpit.
//!
//! Provides SQLite storage for snapshots, file events, and activity tracking.

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use uuid::Uuid;

/// Database connection wrapper.
pub struct Database {
    conn: Connection,
}

/// A snapshot of work context at a point in time.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Snapshot {
    pub id: String,
    pub timestamp: DateTime<Utc>,
    pub active_file: Option<String>,
    pub active_directory: Option<String>,
    pub git_branch: Option<String>,
    pub notes: Option<String>,
}

/// A file change event.
#[derive(Debug, Clone)]
pub struct FileEvent {
    pub id: String,
    pub timestamp: DateTime<Utc>,
    pub path: String,
    pub event_type: FileEventType,
}

/// Type of file event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileEventType {
    Created,
    Modified,
    Deleted,
    Renamed,
}

impl FileEventType {
    fn as_str(&self) -> &'static str {
        match self {
            FileEventType::Created => "created",
            FileEventType::Modified => "modified",
            FileEventType::Deleted => "deleted",
            FileEventType::Renamed => "renamed",
        }
    }

    fn from_str(s: &str) -> Option<Self> {
        match s {
            "created" => Some(FileEventType::Created),
            "modified" => Some(FileEventType::Modified),
            "deleted" => Some(FileEventType::Deleted),
            "renamed" => Some(FileEventType::Renamed),
            _ => None,
        }
    }
}

/// Activity summary for a time period.
#[derive(Debug, Clone)]
pub struct ActivitySummary {
    pub total_events: u64,
    pub files_modified: u64,
    pub files_created: u64,
    pub most_active_directory: Option<String>,
}

impl Database {
    /// Open or create a database at the given path.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();

        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create database directory: {}", parent.display()))?;
        }

        let conn = Connection::open(path)
            .with_context(|| format!("Failed to open database: {}", path.display()))?;

        let db = Self { conn };
        db.initialize_schema()?;
        Ok(db)
    }

    /// Open an in-memory database (useful for testing).
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()
            .context("Failed to open in-memory database")?;
        let db = Self { conn };
        db.initialize_schema()?;
        Ok(db)
    }

    /// Initialize the database schema.
    fn initialize_schema(&self) -> Result<()> {
        self.conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS snapshots (
                id TEXT PRIMARY KEY,
                timestamp TEXT NOT NULL,
                active_file TEXT,
                active_directory TEXT,
                git_branch TEXT,
                notes TEXT
            );

            CREATE TABLE IF NOT EXISTS file_events (
                id TEXT PRIMARY KEY,
                timestamp TEXT NOT NULL,
                path TEXT NOT NULL,
                event_type TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON snapshots(timestamp);
            CREATE INDEX IF NOT EXISTS idx_file_events_timestamp ON file_events(timestamp);
            CREATE INDEX IF NOT EXISTS idx_file_events_path ON file_events(path);
            "#,
        ).context("Failed to initialize database schema")?;

        Ok(())
    }

    /// Insert a new snapshot.
    pub fn insert_snapshot(&self, snapshot: &Snapshot) -> Result<()> {
        self.conn.execute(
            "INSERT INTO snapshots (id, timestamp, active_file, active_directory, git_branch, notes)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                snapshot.id,
                snapshot.timestamp.to_rfc3339(),
                snapshot.active_file,
                snapshot.active_directory,
                snapshot.git_branch,
                snapshot.notes,
            ],
        ).context("Failed to insert snapshot")?;

        Ok(())
    }

    /// Get a snapshot by ID.
    pub fn get_snapshot(&self, id: &str) -> Result<Option<Snapshot>> {
        let snapshot = self.conn.query_row(
            "SELECT id, timestamp, active_file, active_directory, git_branch, notes
             FROM snapshots WHERE id = ?1",
            params![id],
            |row| {
                Ok(Snapshot {
                    id: row.get(0)?,
                    timestamp: DateTime::parse_from_rfc3339(&row.get::<_, String>(1)?)
                        .map(|dt| dt.with_timezone(&Utc))
                        .unwrap_or_else(|_| Utc::now()),
                    active_file: row.get(2)?,
                    active_directory: row.get(3)?,
                    git_branch: row.get(4)?,
                    notes: row.get(5)?,
                })
            },
        ).optional().context("Failed to get snapshot")?;

        Ok(snapshot)
    }

    /// Get recent snapshots.
    pub fn get_recent_snapshots(&self, limit: u32) -> Result<Vec<Snapshot>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, timestamp, active_file, active_directory, git_branch, notes
             FROM snapshots ORDER BY timestamp DESC LIMIT ?1"
        ).context("Failed to prepare snapshot query")?;

        let snapshots = stmt.query_map(params![limit], |row| {
            Ok(Snapshot {
                id: row.get(0)?,
                timestamp: DateTime::parse_from_rfc3339(&row.get::<_, String>(1)?)
                    .map(|dt| dt.with_timezone(&Utc))
                    .unwrap_or_else(|_| Utc::now()),
                active_file: row.get(2)?,
                active_directory: row.get(3)?,
                git_branch: row.get(4)?,
                notes: row.get(5)?,
            })
        }).context("Failed to query snapshots")?;

        snapshots.collect::<Result<Vec<_>, _>>()
            .context("Failed to collect snapshots")
    }

    /// Insert a file event.
    pub fn insert_file_event(&self, event: &FileEvent) -> Result<()> {
        self.conn.execute(
            "INSERT INTO file_events (id, timestamp, path, event_type) VALUES (?1, ?2, ?3, ?4)",
            params![
                event.id,
                event.timestamp.to_rfc3339(),
                event.path,
                event.event_type.as_str(),
            ],
        ).context("Failed to insert file event")?;

        Ok(())
    }

    /// Get file events in a time range.
    pub fn get_file_events(&self, since: DateTime<Utc>, until: DateTime<Utc>) -> Result<Vec<FileEvent>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, timestamp, path, event_type FROM file_events
             WHERE timestamp >= ?1 AND timestamp <= ?2
             ORDER BY timestamp DESC"
        ).context("Failed to prepare file events query")?;

        let events = stmt.query_map(params![since.to_rfc3339(), until.to_rfc3339()], |row| {
            Ok(FileEvent {
                id: row.get(0)?,
                timestamp: DateTime::parse_from_rfc3339(&row.get::<_, String>(1)?)
                    .map(|dt| dt.with_timezone(&Utc))
                    .unwrap_or_else(|_| Utc::now()),
                path: row.get(2)?,
                event_type: FileEventType::from_str(&row.get::<_, String>(3)?)
                    .unwrap_or(FileEventType::Modified),
            })
        }).context("Failed to query file events")?;

        events.collect::<Result<Vec<_>, _>>()
            .context("Failed to collect file events")
    }

    /// Get activity summary for a time range.
    pub fn get_activity_summary(&self, since: DateTime<Utc>, until: DateTime<Utc>) -> Result<ActivitySummary> {
        let total_events: u64 = self.conn.query_row(
            "SELECT COUNT(*) FROM file_events WHERE timestamp >= ?1 AND timestamp <= ?2",
            params![since.to_rfc3339(), until.to_rfc3339()],
            |row| row.get(0),
        ).context("Failed to count file events")?;

        let files_modified: u64 = self.conn.query_row(
            "SELECT COUNT(*) FROM file_events WHERE timestamp >= ?1 AND timestamp <= ?2 AND event_type = 'modified'",
            params![since.to_rfc3339(), until.to_rfc3339()],
            |row| row.get(0),
        ).context("Failed to count modified files")?;

        let files_created: u64 = self.conn.query_row(
            "SELECT COUNT(*) FROM file_events WHERE timestamp >= ?1 AND timestamp <= ?2 AND event_type = 'created'",
            params![since.to_rfc3339(), until.to_rfc3339()],
            |row| row.get(0),
        ).context("Failed to count created files")?;

        // Find most active directory (directory with most events)
        let most_active_directory: Option<String> = self.conn.query_row(
            "SELECT SUBSTR(path, 1, INSTR(path || '/', '/')) as dir
             FROM file_events
             WHERE timestamp >= ?1 AND timestamp <= ?2
             GROUP BY dir
             ORDER BY COUNT(*) DESC
             LIMIT 1",
            params![since.to_rfc3339(), until.to_rfc3339()],
            |row| row.get(0),
        ).optional().context("Failed to find most active directory")?.flatten();

        Ok(ActivitySummary {
            total_events,
            files_modified,
            files_created,
            most_active_directory,
        })
    }

    /// Delete old snapshots to maintain the retention limit.
    pub fn cleanup_old_snapshots(&self, max_snapshots: u32) -> Result<u64> {
        let deleted = self.conn.execute(
            "DELETE FROM snapshots WHERE id NOT IN (
                SELECT id FROM snapshots ORDER BY timestamp DESC LIMIT ?1
            )",
            params![max_snapshots],
        ).context("Failed to cleanup old snapshots")?;

        Ok(deleted as u64)
    }

    /// Delete old file events older than a certain date.
    pub fn cleanup_old_events(&self, older_than: DateTime<Utc>) -> Result<u64> {
        let deleted = self.conn.execute(
            "DELETE FROM file_events WHERE timestamp < ?1",
            params![older_than.to_rfc3339()],
        ).context("Failed to cleanup old events")?;

        Ok(deleted as u64)
    }
}

/// Create a new snapshot with a generated ID and current timestamp.
pub fn new_snapshot() -> Snapshot {
    Snapshot {
        id: Uuid::new_v4().to_string(),
        timestamp: Utc::now(),
        active_file: None,
        active_directory: None,
        git_branch: None,
        notes: None,
    }
}

/// Create a new file event with a generated ID and current timestamp.
pub fn new_file_event(path: String, event_type: FileEventType) -> FileEvent {
    FileEvent {
        id: Uuid::new_v4().to_string(),
        timestamp: Utc::now(),
        path,
        event_type,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn test_open_in_memory() {
        let db = Database::open_in_memory().unwrap();
        assert!(db.get_recent_snapshots(10).unwrap().is_empty());
    }

    #[test]
    fn test_insert_and_get_snapshot() {
        let db = Database::open_in_memory().unwrap();

        let mut snapshot = new_snapshot();
        snapshot.active_file = Some("/path/to/file.rs".to_string());
        snapshot.active_directory = Some("/path/to".to_string());
        snapshot.git_branch = Some("main".to_string());
        snapshot.notes = Some("Working on tests".to_string());

        db.insert_snapshot(&snapshot).unwrap();

        let retrieved = db.get_snapshot(&snapshot.id).unwrap().unwrap();
        assert_eq!(retrieved.id, snapshot.id);
        assert_eq!(retrieved.active_file, snapshot.active_file);
        assert_eq!(retrieved.git_branch, Some("main".to_string()));
    }

    #[test]
    fn test_get_recent_snapshots() {
        let db = Database::open_in_memory().unwrap();

        for i in 0..5 {
            let mut snapshot = new_snapshot();
            snapshot.notes = Some(format!("Snapshot {}", i));
            db.insert_snapshot(&snapshot).unwrap();
        }

        let recent = db.get_recent_snapshots(3).unwrap();
        assert_eq!(recent.len(), 3);
    }

    #[test]
    fn test_insert_and_get_file_events() {
        let db = Database::open_in_memory().unwrap();

        let event = new_file_event("/src/main.rs".to_string(), FileEventType::Modified);
        db.insert_file_event(&event).unwrap();

        let since = Utc::now() - Duration::hours(1);
        let until = Utc::now() + Duration::hours(1);
        let events = db.get_file_events(since, until).unwrap();

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].path, "/src/main.rs");
        assert_eq!(events[0].event_type, FileEventType::Modified);
    }

    #[test]
    fn test_activity_summary() {
        let db = Database::open_in_memory().unwrap();

        // Insert various events
        db.insert_file_event(&new_file_event("/src/a.rs".to_string(), FileEventType::Modified)).unwrap();
        db.insert_file_event(&new_file_event("/src/b.rs".to_string(), FileEventType::Modified)).unwrap();
        db.insert_file_event(&new_file_event("/src/c.rs".to_string(), FileEventType::Created)).unwrap();
        db.insert_file_event(&new_file_event("/test/d.rs".to_string(), FileEventType::Deleted)).unwrap();

        let since = Utc::now() - Duration::hours(1);
        let until = Utc::now() + Duration::hours(1);
        let summary = db.get_activity_summary(since, until).unwrap();

        assert_eq!(summary.total_events, 4);
        assert_eq!(summary.files_modified, 2);
        assert_eq!(summary.files_created, 1);
    }

    #[test]
    fn test_cleanup_old_snapshots() {
        let db = Database::open_in_memory().unwrap();

        for _ in 0..10 {
            db.insert_snapshot(&new_snapshot()).unwrap();
        }

        let deleted = db.cleanup_old_snapshots(5).unwrap();
        assert_eq!(deleted, 5);

        let remaining = db.get_recent_snapshots(100).unwrap();
        assert_eq!(remaining.len(), 5);
    }

    #[test]
    fn test_file_event_type_conversion() {
        assert_eq!(FileEventType::Created.as_str(), "created");
        assert_eq!(FileEventType::from_str("modified"), Some(FileEventType::Modified));
        assert_eq!(FileEventType::from_str("invalid"), None);
    }
}
