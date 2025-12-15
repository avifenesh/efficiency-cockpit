//! AI integration module for the Efficiency Cockpit.
//!
//! Provides AI-assisted insights and suggestions (stub for external API integration).

use anyhow::Result;
use chrono::Timelike;

use crate::db::Snapshot;
use crate::gatekeeper::DailySummary;

/// AI service for generating insights.
pub struct AiService {
    config: AiServiceConfig,
}

/// Configuration for the AI service.
#[derive(Debug, Clone)]
#[derive(Default)]
pub struct AiServiceConfig {
    /// Whether AI features are enabled
    pub enabled: bool,
    /// API endpoint (if using external service)
    pub api_endpoint: Option<String>,
    /// API key (should be from environment)
    pub api_key: Option<String>,
}


/// An AI-generated insight.
#[derive(Debug, Clone)]
pub struct Insight {
    pub title: String,
    pub description: String,
    pub confidence: f32,
    pub insight_type: InsightType,
}

/// Type of insight.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InsightType {
    /// Productivity pattern detected
    ProductivityPattern,
    /// Suggestion for improvement
    Suggestion,
    /// Anomaly detected
    Anomaly,
    /// Achievement/milestone
    Achievement,
}

impl AiService {
    /// Create a new AI service.
    pub fn new(config: AiServiceConfig) -> Self {
        Self { config }
    }

    /// Check if AI features are available.
    pub fn is_available(&self) -> bool {
        self.config.enabled && self.config.api_key.is_some()
    }

    /// Generate insights from recent snapshots.
    pub fn generate_insights(&self, snapshots: &[Snapshot]) -> Result<Vec<Insight>> {
        if !self.config.enabled {
            return Ok(Vec::new());
        }

        // For now, use rule-based insights (AI API integration would go here)
        let mut insights = Vec::new();

        // Detect productivity patterns
        if let Some(insight) = self.detect_productivity_pattern(snapshots) {
            insights.push(insight);
        }

        // Detect achievements
        if let Some(insight) = self.detect_achievements(snapshots) {
            insights.push(insight);
        }

        Ok(insights)
    }

    /// Generate a summary insight from daily activity.
    pub fn summarize_day(&self, summary: &DailySummary) -> Result<Option<Insight>> {
        if !self.config.enabled {
            return Ok(None);
        }

        if summary.total_events == 0 {
            return Ok(None);
        }

        let description = if summary.total_events > 100 {
            "Very high activity today! Great productivity.".to_string()
        } else if summary.total_events > 50 {
            "Solid day of work with good activity levels.".to_string()
        } else if summary.total_events > 20 {
            "Moderate activity today.".to_string()
        } else {
            "Light activity day. Consider if this was intentional.".to_string()
        };

        Ok(Some(Insight {
            title: "Daily Activity Summary".to_string(),
            description,
            confidence: 0.8,
            insight_type: InsightType::ProductivityPattern,
        }))
    }

    /// Detect productivity patterns from snapshots.
    fn detect_productivity_pattern(&self, snapshots: &[Snapshot]) -> Option<Insight> {
        if snapshots.len() < 10 {
            return None;
        }

        // Check for consistent directory focus
        let first_dir = snapshots.first()?.active_directory.as_ref()?;
        let same_dir_count = snapshots
            .iter()
            .filter(|s| s.active_directory.as_ref() == Some(first_dir))
            .count();

        if same_dir_count > snapshots.len() / 2 {
            return Some(Insight {
                title: "Focused Work Session".to_string(),
                description: format!(
                    "You've been consistently working in {}. Great focus!",
                    first_dir
                ),
                confidence: 0.7,
                insight_type: InsightType::ProductivityPattern,
            });
        }

        None
    }

    /// Detect achievements from snapshots.
    fn detect_achievements(&self, snapshots: &[Snapshot]) -> Option<Insight> {
        if snapshots.len() >= 100 {
            return Some(Insight {
                title: "Session Milestone".to_string(),
                description: "100+ context captures in this session. You're on a roll!".to_string(),
                confidence: 0.9,
                insight_type: InsightType::Achievement,
            });
        }

        None
    }

    /// Generate suggestions based on activity.
    pub fn generate_suggestions(&self, snapshots: &[Snapshot]) -> Result<Vec<String>> {
        if !self.config.enabled {
            return Ok(Vec::new());
        }

        let mut suggestions = Vec::new();

        // Suggest based on time of day
        let hour = chrono::Local::now().hour();
        if hour >= 17 {
            suggestions.push("Consider wrapping up and reviewing today's work.".to_string());
        }

        // Suggest based on activity
        if snapshots.len() > 50 {
            suggestions.push("High activity session! Take a break when ready.".to_string());
        }

        // Suggest based on context switches
        let unique_dirs: std::collections::HashSet<_> = snapshots
            .iter()
            .filter_map(|s| s.active_directory.as_ref())
            .collect();

        if unique_dirs.len() > 5 {
            suggestions.push(
                "You've touched many different areas. Consider focusing on completing one task fully."
                    .to_string(),
            );
        }

        Ok(suggestions)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::new_snapshot;
    use chrono::Utc;

    #[test]
    fn test_ai_service_disabled() {
        let config = AiServiceConfig::default();
        let service = AiService::new(config);

        assert!(!service.is_available());

        let insights = service.generate_insights(&[]).unwrap();
        assert!(insights.is_empty());
    }

    #[test]
    fn test_ai_service_enabled() {
        let config = AiServiceConfig {
            enabled: true,
            api_endpoint: None,
            api_key: Some("test_key".to_string()),
        };
        let service = AiService::new(config);

        assert!(service.is_available());
    }

    #[test]
    fn test_generate_insights_empty() {
        let config = AiServiceConfig {
            enabled: true,
            api_key: Some("key".to_string()),
            ..Default::default()
        };
        let service = AiService::new(config);

        let insights = service.generate_insights(&[]).unwrap();
        assert!(insights.is_empty());
    }

    #[test]
    fn test_detect_focused_work() {
        let config = AiServiceConfig {
            enabled: true,
            api_key: Some("key".to_string()),
            ..Default::default()
        };
        let service = AiService::new(config);

        let mut snapshots = Vec::new();
        for _ in 0..15 {
            let mut snapshot = new_snapshot();
            snapshot.active_directory = Some("/src/project".to_string());
            snapshots.push(snapshot);
        }

        let insights = service.generate_insights(&snapshots).unwrap();
        assert!(insights.iter().any(|i| i.insight_type == InsightType::ProductivityPattern));
    }

    #[test]
    fn test_summarize_day() {
        let config = AiServiceConfig {
            enabled: true,
            api_key: Some("key".to_string()),
            ..Default::default()
        };
        let service = AiService::new(config);

        let summary = DailySummary {
            date: Utc::now(),
            total_events: 75,
            files_modified: 50,
            files_created: 10,
            most_active_directory: Some("/project".to_string()),
        };

        let insight = service.summarize_day(&summary).unwrap();
        assert!(insight.is_some());
        assert!(insight.unwrap().description.contains("Solid"));
    }

    #[test]
    fn test_generate_suggestions() {
        let config = AiServiceConfig {
            enabled: true,
            api_key: Some("key".to_string()),
            ..Default::default()
        };
        let service = AiService::new(config);

        let snapshots: Vec<Snapshot> = (0..60)
            .map(|i| {
                let mut s = new_snapshot();
                s.active_directory = Some(format!("/dir{}", i % 10));
                s
            })
            .collect();

        let suggestions = service.generate_suggestions(&snapshots).unwrap();
        assert!(!suggestions.is_empty());
    }

    #[test]
    fn test_achievement_detection() {
        let config = AiServiceConfig {
            enabled: true,
            api_key: Some("key".to_string()),
            ..Default::default()
        };
        let service = AiService::new(config);

        let snapshots: Vec<Snapshot> = (0..100).map(|_| new_snapshot()).collect();
        let insights = service.generate_insights(&snapshots).unwrap();

        assert!(insights.iter().any(|i| i.insight_type == InsightType::Achievement));
    }
}
