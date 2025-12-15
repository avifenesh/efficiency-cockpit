//! Decision gatekeeper module for the Efficiency Cockpit.
//!
//! Provides nudges and decision support based on activity patterns.

use chrono::{DateTime, Duration, Utc};

use crate::db::{ActivitySummary, Database, Snapshot};

/// Gatekeeper service for decision support.
pub struct Gatekeeper<'a> {
    db: &'a Database,
    config: GatekeeperConfig,
}

/// Configuration for the gatekeeper.
#[derive(Debug, Clone)]
pub struct GatekeeperConfig {
    /// Maximum nudges per day
    pub max_nudges_per_day: u32,
    /// Enable context switch nudges
    pub enable_context_switch_nudges: bool,
    /// Minimum time on task before nudge (minutes)
    pub min_focus_time_minutes: u32,
    /// Maximum time on task before break nudge (minutes)
    pub max_focus_time_minutes: u32,
}

impl Default for GatekeeperConfig {
    fn default() -> Self {
        Self {
            max_nudges_per_day: 2,
            enable_context_switch_nudges: true,
            min_focus_time_minutes: 15,
            max_focus_time_minutes: 90,
        }
    }
}

/// A nudge or suggestion from the gatekeeper.
#[derive(Debug, Clone)]
pub struct Nudge {
    pub message: String,
    pub nudge_type: NudgeType,
    pub priority: NudgePriority,
    pub timestamp: DateTime<Utc>,
}

/// Type of nudge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NudgeType {
    /// Suggest taking a break
    TakeBreak,
    /// Suggest switching context
    ContextSwitch,
    /// Remind about unfocused activity
    FocusReminder,
    /// Daily summary available
    DailySummary,
    /// High activity detected
    HighActivity,
}

/// Priority level of a nudge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum NudgePriority {
    Low,
    Medium,
    High,
}

impl<'a> Gatekeeper<'a> {
    /// Create a new gatekeeper with the given database and config.
    pub fn new(db: &'a Database, config: GatekeeperConfig) -> Self {
        Self { db, config }
    }

    /// Analyze recent activity and generate nudges.
    pub fn analyze(&self) -> Vec<Nudge> {
        let mut nudges = Vec::new();

        // Get recent snapshots for analysis
        let snapshots = self.db.get_recent_snapshots(50).unwrap_or_default();

        if let Some(nudge) = self.check_focus_time(&snapshots) {
            nudges.push(nudge);
        }

        if self.config.enable_context_switch_nudges {
            if let Some(nudge) = self.check_context_switches(&snapshots) {
                nudges.push(nudge);
            }
        }

        if let Some(nudge) = self.check_activity_level(&snapshots) {
            nudges.push(nudge);
        }

        // Sort by priority (highest first)
        nudges.sort_by(|a, b| b.priority.cmp(&a.priority));

        // Limit to max nudges
        nudges.truncate(self.config.max_nudges_per_day as usize);

        nudges
    }

    /// Check if user has been focused too long and needs a break.
    fn check_focus_time(&self, snapshots: &[Snapshot]) -> Option<Nudge> {
        if snapshots.is_empty() {
            return None;
        }

        let now = Utc::now();
        let oldest = snapshots.last()?;
        let newest = snapshots.first()?;

        // Check if same directory for extended time
        if oldest.active_directory == newest.active_directory {
            let focus_duration = now.signed_duration_since(oldest.timestamp);
            let max_focus = Duration::minutes(self.config.max_focus_time_minutes as i64);

            if focus_duration > max_focus {
                return Some(Nudge {
                    message: format!(
                        "You've been working in the same area for over {} minutes. Consider taking a short break!",
                        self.config.max_focus_time_minutes
                    ),
                    nudge_type: NudgeType::TakeBreak,
                    priority: NudgePriority::Medium,
                    timestamp: now,
                });
            }
        }

        None
    }

    /// Check for too many context switches.
    fn check_context_switches(&self, snapshots: &[Snapshot]) -> Option<Nudge> {
        if snapshots.len() < 5 {
            return None;
        }

        // Count unique directories in recent snapshots
        let unique_dirs: std::collections::HashSet<_> = snapshots
            .iter()
            .take(10)
            .filter_map(|s| s.active_directory.as_ref())
            .collect();

        if unique_dirs.len() >= 5 {
            return Some(Nudge {
                message: "You've switched context frequently. Consider focusing on one area.".to_string(),
                nudge_type: NudgeType::ContextSwitch,
                priority: NudgePriority::Low,
                timestamp: Utc::now(),
            });
        }

        None
    }

    /// Check activity level and provide feedback.
    fn check_activity_level(&self, snapshots: &[Snapshot]) -> Option<Nudge> {
        if snapshots.len() < 20 {
            return None;
        }

        // High activity if many snapshots in short time
        if let (Some(newest), Some(oldest)) = (snapshots.first(), snapshots.get(19)) {
            let duration = newest.timestamp.signed_duration_since(oldest.timestamp);

            if duration < Duration::minutes(30) {
                return Some(Nudge {
                    message: "High activity detected! You're making great progress.".to_string(),
                    nudge_type: NudgeType::HighActivity,
                    priority: NudgePriority::Low,
                    timestamp: Utc::now(),
                });
            }
        }

        None
    }

    /// Generate a daily summary.
    pub fn daily_summary(&self, date: DateTime<Utc>) -> DailySummary {
        let start_of_day = date
            .date_naive()
            .and_hms_opt(0, 0, 0)
            .map(|dt| DateTime::from_naive_utc_and_offset(dt, Utc))
            .unwrap_or(date);
        let end_of_day = start_of_day + Duration::days(1);

        let activity = self.db
            .get_activity_summary(start_of_day, end_of_day)
            .unwrap_or(ActivitySummary {
                total_events: 0,
                files_modified: 0,
                files_created: 0,
                most_active_directory: None,
            });

        DailySummary {
            date,
            total_events: activity.total_events,
            files_modified: activity.files_modified,
            files_created: activity.files_created,
            most_active_directory: activity.most_active_directory,
        }
    }
}

/// Daily activity summary.
#[derive(Debug, Clone)]
pub struct DailySummary {
    pub date: DateTime<Utc>,
    pub total_events: u64,
    pub files_modified: u64,
    pub files_created: u64,
    pub most_active_directory: Option<String>,
}

impl DailySummary {
    /// Generate a human-readable summary.
    pub fn to_message(&self) -> String {
        let mut parts = Vec::new();

        if self.total_events > 0 {
            parts.push(format!("{} file events", self.total_events));
        }

        if self.files_modified > 0 {
            parts.push(format!("{} files modified", self.files_modified));
        }

        if self.files_created > 0 {
            parts.push(format!("{} files created", self.files_created));
        }

        if let Some(ref dir) = self.most_active_directory {
            parts.push(format!("Most active: {}", dir));
        }

        if parts.is_empty() {
            "No activity recorded today.".to_string()
        } else {
            parts.join(" | ")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::{self, new_snapshot};

    fn create_test_db() -> Database {
        Database::open_in_memory().unwrap()
    }

    #[test]
    fn test_gatekeeper_creation() {
        let db = create_test_db();
        let gatekeeper = Gatekeeper::new(&db, GatekeeperConfig::default());
        let nudges = gatekeeper.analyze();
        assert!(nudges.is_empty()); // No data, no nudges
    }

    #[test]
    fn test_context_switch_detection() {
        let db = create_test_db();

        // Insert snapshots with different directories
        for i in 0..10 {
            let mut snapshot = new_snapshot();
            snapshot.active_directory = Some(format!("/project{}", i));
            db.insert_snapshot(&snapshot).unwrap();
        }

        let config = GatekeeperConfig {
            enable_context_switch_nudges: true,
            ..Default::default()
        };

        let gatekeeper = Gatekeeper::new(&db, config);
        let nudges = gatekeeper.analyze();

        assert!(nudges.iter().any(|n| n.nudge_type == NudgeType::ContextSwitch));
    }

    #[test]
    fn test_daily_summary_empty() {
        let db = create_test_db();
        let gatekeeper = Gatekeeper::new(&db, GatekeeperConfig::default());

        let summary = gatekeeper.daily_summary(Utc::now());
        assert_eq!(summary.total_events, 0);
        assert!(summary.to_message().contains("No activity"));
    }

    #[test]
    fn test_daily_summary_with_activity() {
        let db = create_test_db();

        // Add some file events
        db.insert_file_event(&db::new_file_event("/src/main.rs".to_string(), db::FileEventType::Modified)).unwrap();
        db.insert_file_event(&db::new_file_event("/src/lib.rs".to_string(), db::FileEventType::Created)).unwrap();

        let gatekeeper = Gatekeeper::new(&db, GatekeeperConfig::default());
        let summary = gatekeeper.daily_summary(Utc::now());

        assert!(summary.total_events >= 2);
    }

    #[test]
    fn test_nudge_priority_ordering() {
        let nudges = vec![
            Nudge {
                message: "Low".to_string(),
                nudge_type: NudgeType::HighActivity,
                priority: NudgePriority::Low,
                timestamp: Utc::now(),
            },
            Nudge {
                message: "High".to_string(),
                nudge_type: NudgeType::TakeBreak,
                priority: NudgePriority::High,
                timestamp: Utc::now(),
            },
            Nudge {
                message: "Medium".to_string(),
                nudge_type: NudgeType::ContextSwitch,
                priority: NudgePriority::Medium,
                timestamp: Utc::now(),
            },
        ];

        let mut sorted = nudges.clone();
        sorted.sort_by(|a, b| b.priority.cmp(&a.priority));

        assert_eq!(sorted[0].priority, NudgePriority::High);
        assert_eq!(sorted[1].priority, NudgePriority::Medium);
        assert_eq!(sorted[2].priority, NudgePriority::Low);
    }

    #[test]
    fn test_default_config() {
        let config = GatekeeperConfig::default();
        assert_eq!(config.max_nudges_per_day, 2);
        assert!(config.enable_context_switch_nudges);
        assert_eq!(config.min_focus_time_minutes, 15);
        assert_eq!(config.max_focus_time_minutes, 90);
    }
}
