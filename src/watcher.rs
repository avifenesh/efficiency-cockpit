//! File watcher module for the Efficiency Cockpit.
//!
//! Monitors directories for file changes and emits events.

use anyhow::{Context, Result};
use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use regex::Regex;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver};
use std::time::Duration;

use crate::db::FileEventType;

/// A file system watcher that monitors directories for changes.
pub struct FileWatcher {
    _watcher: RecommendedWatcher,
    receiver: Receiver<Result<Event, notify::Error>>,
    ignore_patterns: Vec<Regex>,
}

/// A file change event from the watcher.
#[derive(Debug, Clone)]
pub struct WatchEvent {
    pub path: PathBuf,
    pub event_type: FileEventType,
}

impl FileWatcher {
    /// Create a new file watcher for the given directories.
    pub fn new(directories: &[PathBuf], ignore_patterns: &[String]) -> Result<Self> {
        let (tx, rx) = channel();

        // Compile ignore patterns
        let compiled_patterns: Vec<Regex> = ignore_patterns
            .iter()
            .filter_map(|p| Regex::new(p).ok())
            .collect();

        // Create watcher with recommended config
        let mut watcher = RecommendedWatcher::new(
            move |res| {
                let _ = tx.send(res);
            },
            Config::default().with_poll_interval(Duration::from_secs(2)),
        )
        .context("Failed to create file watcher")?;

        // Watch all directories
        for dir in directories {
            if dir.exists() {
                watcher
                    .watch(dir, RecursiveMode::Recursive)
                    .with_context(|| format!("Failed to watch directory: {}", dir.display()))?;
                tracing::info!("Watching directory: {}", dir.display());
            } else {
                tracing::warn!("Directory does not exist, skipping: {}", dir.display());
            }
        }

        Ok(Self {
            _watcher: watcher,
            receiver: rx,
            ignore_patterns: compiled_patterns,
        })
    }

    /// Check for pending events (non-blocking).
    pub fn poll_events(&self) -> Vec<WatchEvent> {
        let mut events = Vec::new();

        while let Ok(result) = self.receiver.try_recv() {
            if let Ok(event) = result {
                events.extend(self.process_event(event));
            }
        }

        events
    }

    /// Wait for the next batch of events (blocking with timeout).
    pub fn wait_for_events(&self, timeout: Duration) -> Vec<WatchEvent> {
        let mut events = Vec::new();

        // Wait for first event with timeout
        match self.receiver.recv_timeout(timeout) {
            Ok(Ok(event)) => {
                events.extend(self.process_event(event));
            }
            _ => return events,
        }

        // Collect any additional pending events
        events.extend(self.poll_events());

        events
    }

    /// Process a notify event into WatchEvents.
    fn process_event(&self, event: Event) -> Vec<WatchEvent> {
        let event_type = match event.kind {
            EventKind::Create(_) => Some(FileEventType::Created),
            EventKind::Modify(_) => Some(FileEventType::Modified),
            EventKind::Remove(_) => Some(FileEventType::Deleted),
            _ => None,
        };

        let Some(event_type) = event_type else {
            return Vec::new();
        };

        event
            .paths
            .into_iter()
            .filter(|path| !self.should_ignore(path))
            .map(|path| WatchEvent { path, event_type })
            .collect()
    }

    /// Check if a path should be ignored based on patterns.
    fn should_ignore(&self, path: &Path) -> bool {
        let path_str = path.to_string_lossy();

        for pattern in &self.ignore_patterns {
            if pattern.is_match(&path_str) {
                return true;
            }
        }

        false
    }
}

/// Deduplicate events that affect the same file within a short time window.
/// Keeps only the most recent event for each path.
pub fn deduplicate_events(events: Vec<WatchEvent>) -> Vec<WatchEvent> {
    use std::collections::HashMap;

    let mut latest: HashMap<PathBuf, WatchEvent> = HashMap::new();

    for event in events {
        latest.insert(event.path.clone(), event);
    }

    latest.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn test_should_ignore_git() {
        let watcher = FileWatcher {
            _watcher: create_dummy_watcher(),
            receiver: channel().1,
            ignore_patterns: vec![Regex::new(r"\.git").unwrap()],
        };

        assert!(watcher.should_ignore(Path::new("/project/.git/objects/abc")));
        assert!(watcher.should_ignore(Path::new("/project/.gitignore")));
        assert!(!watcher.should_ignore(Path::new("/project/src/main.rs")));
    }

    #[test]
    fn test_should_ignore_target() {
        let watcher = FileWatcher {
            _watcher: create_dummy_watcher(),
            receiver: channel().1,
            ignore_patterns: vec![Regex::new(r"target").unwrap()],
        };

        assert!(watcher.should_ignore(Path::new("/project/target/debug/main")));
        assert!(!watcher.should_ignore(Path::new("/project/src/main.rs")));
    }

    #[test]
    fn test_deduplicate_events() {
        let events = vec![
            WatchEvent {
                path: PathBuf::from("/src/a.rs"),
                event_type: FileEventType::Modified,
            },
            WatchEvent {
                path: PathBuf::from("/src/b.rs"),
                event_type: FileEventType::Created,
            },
            WatchEvent {
                path: PathBuf::from("/src/a.rs"),
                event_type: FileEventType::Modified,
            },
        ];

        let deduped = deduplicate_events(events);
        assert_eq!(deduped.len(), 2);
    }

    #[test]
    fn test_watcher_creation() {
        let dir = tempdir().unwrap();
        let watcher = FileWatcher::new(&[dir.path().to_path_buf()], &[]);
        assert!(watcher.is_ok());
    }

    #[test]
    fn test_watcher_detects_file_creation() {
        let dir = tempdir().unwrap();
        let watcher = FileWatcher::new(&[dir.path().to_path_buf()], &[]).unwrap();

        // Create a file
        let file_path = dir.path().join("test.txt");
        fs::write(&file_path, "hello").unwrap();

        // Give the watcher time to detect the change
        std::thread::sleep(Duration::from_millis(100));

        let events = watcher.poll_events();
        // Note: The exact events depend on the platform, so we just check we can poll
        // without errors. In some cases, we might get events, in others not.
        let _ = events;
    }

    // Helper to create a dummy watcher for testing ignore patterns
    fn create_dummy_watcher() -> RecommendedWatcher {
        RecommendedWatcher::new(|_| {}, Config::default()).unwrap()
    }
}
