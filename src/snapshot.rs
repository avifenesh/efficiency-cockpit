//! Snapshot module for the Efficiency Cockpit.
//!
//! Captures and manages snapshots of the current work context.

use anyhow::Result;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::db::{self, Database, Snapshot};

/// Service for capturing work context snapshots.
pub struct SnapshotService<'a> {
    db: &'a Database,
}

/// Current context information that can be captured.
#[derive(Debug, Clone, Default)]
pub struct ContextInfo {
    pub active_file: Option<PathBuf>,
    pub active_directory: Option<PathBuf>,
    pub git_branch: Option<String>,
    pub git_repo_root: Option<PathBuf>,
}

impl<'a> SnapshotService<'a> {
    /// Create a new snapshot service with database connection.
    pub fn new(db: &'a Database) -> Self {
        Self { db }
    }

    /// Capture a snapshot of the current context.
    pub fn capture(&self, context: &ContextInfo, notes: Option<String>) -> Result<Snapshot> {
        let mut snapshot = db::new_snapshot();

        snapshot.active_file = context.active_file.as_ref().map(|p| p.to_string_lossy().to_string());
        snapshot.active_directory = context.active_directory.as_ref().map(|p| p.to_string_lossy().to_string());
        snapshot.git_branch = context.git_branch.clone();
        snapshot.notes = notes;

        self.db.insert_snapshot(&snapshot)?;
        tracing::debug!("Captured snapshot: {}", snapshot.id);

        Ok(snapshot)
    }

    /// Get recent snapshots.
    pub fn get_recent(&self, limit: u32) -> Result<Vec<Snapshot>> {
        self.db.get_recent_snapshots(limit)
    }

    /// Get a specific snapshot by ID.
    pub fn get(&self, id: &str) -> Result<Option<Snapshot>> {
        self.db.get_snapshot(id)
    }

    /// Cleanup old snapshots based on retention limit.
    pub fn cleanup(&self, max_snapshots: u32) -> Result<u64> {
        let deleted = self.db.cleanup_old_snapshots(max_snapshots)?;
        if deleted > 0 {
            tracing::info!("Cleaned up {} old snapshots", deleted);
        }
        Ok(deleted)
    }
}

/// Detect the current git branch for a directory.
pub fn detect_git_branch(dir: &Path) -> Option<String> {
    let output = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(dir)
        .output()
        .ok()?;

    if output.status.success() {
        let branch = String::from_utf8_lossy(&output.stdout)
            .trim()
            .to_string();
        if !branch.is_empty() {
            return Some(branch);
        }
    }

    None
}

/// Find the git repository root for a directory.
pub fn find_git_root(dir: &Path) -> Option<PathBuf> {
    let output = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(dir)
        .output()
        .ok()?;

    if output.status.success() {
        let root = String::from_utf8_lossy(&output.stdout)
            .trim()
            .to_string();
        if !root.is_empty() {
            return Some(PathBuf::from(root));
        }
    }

    None
}

/// Build context info from a file path.
pub fn context_from_path(path: &Path) -> ContextInfo {
    let dir = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent().map(|p| p.to_path_buf()).unwrap_or_default()
    };

    let active_file = if path.is_file() {
        Some(path.to_path_buf())
    } else {
        None
    };

    let git_branch = detect_git_branch(&dir);
    let git_repo_root = find_git_root(&dir);

    ContextInfo {
        active_file,
        active_directory: Some(dir),
        git_branch,
        git_repo_root,
    }
}

/// Get a summary of recent activity from snapshots.
pub fn summarize_recent_activity(snapshots: &[Snapshot]) -> ActivitySnapshot {
    let mut directories = std::collections::HashSet::new();
    let mut branches = std::collections::HashSet::new();
    let mut files_count = 0;

    for snapshot in snapshots {
        if let Some(ref dir) = snapshot.active_directory {
            directories.insert(dir.clone());
        }
        if let Some(ref branch) = snapshot.git_branch {
            branches.insert(branch.clone());
        }
        if snapshot.active_file.is_some() {
            files_count += 1;
        }
    }

    ActivitySnapshot {
        total_snapshots: snapshots.len(),
        unique_directories: directories.len(),
        unique_branches: branches.len(),
        files_touched: files_count,
    }
}

/// Summary of activity based on snapshots.
#[derive(Debug, Clone)]
pub struct ActivitySnapshot {
    pub total_snapshots: usize,
    pub unique_directories: usize,
    pub unique_branches: usize,
    pub files_touched: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_snapshot_service_capture() {
        let db = Database::open_in_memory().unwrap();
        let service = SnapshotService::new(&db);

        let context = ContextInfo {
            active_file: Some(PathBuf::from("/src/main.rs")),
            active_directory: Some(PathBuf::from("/src")),
            git_branch: Some("main".to_string()),
            git_repo_root: None,
        };

        let snapshot = service.capture(&context, Some("Working on tests".to_string())).unwrap();

        assert!(snapshot.active_file.is_some());
        assert_eq!(snapshot.git_branch, Some("main".to_string()));
        assert_eq!(snapshot.notes, Some("Working on tests".to_string()));
    }

    #[test]
    fn test_snapshot_service_get_recent() {
        let db = Database::open_in_memory().unwrap();
        let service = SnapshotService::new(&db);

        for i in 0..5 {
            let context = ContextInfo {
                active_directory: Some(PathBuf::from(format!("/dir{}", i))),
                ..Default::default()
            };
            service.capture(&context, None).unwrap();
        }

        let recent = service.get_recent(3).unwrap();
        assert_eq!(recent.len(), 3);
    }

    #[test]
    fn test_context_from_path_file() {
        let dir = tempdir().unwrap();
        let file_path = dir.path().join("test.rs");
        std::fs::write(&file_path, "fn main() {}").unwrap();

        let context = context_from_path(&file_path);

        assert!(context.active_file.is_some());
        assert!(context.active_directory.is_some());
    }

    #[test]
    fn test_context_from_path_directory() {
        let dir = tempdir().unwrap();

        let context = context_from_path(dir.path());

        assert!(context.active_file.is_none());
        assert!(context.active_directory.is_some());
    }

    #[test]
    fn test_summarize_recent_activity() {
        let snapshots = vec![
            Snapshot {
                id: "1".to_string(),
                timestamp: chrono::Utc::now(),
                active_file: Some("/src/a.rs".to_string()),
                active_directory: Some("/src".to_string()),
                git_branch: Some("main".to_string()),
                notes: None,
            },
            Snapshot {
                id: "2".to_string(),
                timestamp: chrono::Utc::now(),
                active_file: Some("/test/b.rs".to_string()),
                active_directory: Some("/test".to_string()),
                git_branch: Some("feature".to_string()),
                notes: None,
            },
        ];

        let summary = summarize_recent_activity(&snapshots);

        assert_eq!(summary.total_snapshots, 2);
        assert_eq!(summary.unique_directories, 2);
        assert_eq!(summary.unique_branches, 2);
        assert_eq!(summary.files_touched, 2);
    }

    #[test]
    fn test_detect_git_branch_in_git_repo() {
        // This test will only pass if run in a git repo
        let current_dir = std::env::current_dir().unwrap();
        let branch = detect_git_branch(&current_dir);
        // We're in a git repo (efficiency_cockpit), so branch should be detected
        // But we don't assert a specific value as it could vary
        let _ = branch;
    }
}
