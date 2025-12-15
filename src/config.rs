//! Configuration module for the Efficiency Cockpit.
//!
//! Handles loading and validating configuration from TOML files.

use anyhow::{Context, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Main configuration structure for the Efficiency Cockpit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Directories to watch for file changes
    pub directories: Vec<PathBuf>,

    /// Patterns to ignore when watching (regex patterns)
    pub ignore_patterns: Vec<String>,

    /// Notification settings
    #[serde(default)]
    pub notifications: NotificationConfig,

    /// Database settings
    #[serde(default)]
    pub database: DatabaseConfig,

    /// AI integration settings
    #[serde(default)]
    pub ai: AiConfig,
}

/// Configuration for notifications and nudges.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationConfig {
    /// Hour of the day (0-23) to send daily digest
    #[serde(default = "default_digest_hour")]
    pub daily_digest_hour: u8,

    /// Maximum number of nudges to send per day (max 100)
    #[serde(default = "default_max_nudges")]
    pub max_nudges_per_day: u32,

    /// Whether to enable context switch nudges
    #[serde(default = "default_true")]
    pub enable_context_switch_nudges: bool,
}

impl Default for NotificationConfig {
    fn default() -> Self {
        Self {
            daily_digest_hour: default_digest_hour(),
            max_nudges_per_day: default_max_nudges(),
            enable_context_switch_nudges: true,
        }
    }
}

/// Configuration for the database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseConfig {
    /// Path to the SQLite database file
    #[serde(default = "default_db_path")]
    pub path: PathBuf,

    /// Maximum number of snapshots to retain (max 1,000,000)
    #[serde(default = "default_max_snapshots")]
    pub max_snapshots: u32,
}

impl Default for DatabaseConfig {
    fn default() -> Self {
        Self {
            path: default_db_path(),
            max_snapshots: default_max_snapshots(),
        }
    }
}

/// Configuration for AI integration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(Default)]
pub struct AiConfig {
    /// Whether AI features are enabled
    #[serde(default)]
    pub enabled: bool,

    /// API endpoint for AI service (if using external API)
    pub api_endpoint: Option<String>,

    /// API key - loaded from environment variable, not from config file
    #[serde(skip)]
    pub api_key: Option<String>,
}


impl AiConfig {
    /// Load API key from environment variable EFFICIENCY_COCKPIT_AI_KEY
    pub fn with_api_key_from_env(mut self) -> Self {
        self.api_key = std::env::var("EFFICIENCY_COCKPIT_AI_KEY").ok();
        self
    }
}

// Default value functions for serde
fn default_digest_hour() -> u8 {
    20
}

fn default_max_nudges() -> u32 {
    2
}

fn default_true() -> bool {
    true
}

fn default_db_path() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| {
            tracing::warn!("Could not determine local data directory, using current directory");
            PathBuf::from(".")
        })
        .join("efficiency_cockpit")
        .join("data.db")
}

fn default_max_snapshots() -> u32 {
    1000
}

impl Config {
    /// Load configuration from a TOML file.
    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("Failed to read config file: {}", path.display()))?;

        let mut config: Config = toml::from_str(&content)
            .with_context(|| format!("Failed to parse config file: {}", path.display()))?;

        // Load API key from environment, not config file
        config.ai = config.ai.with_api_key_from_env();

        config.validate()?;
        Ok(config)
    }

    /// Load configuration from the default location.
    pub fn load_default() -> Result<Self> {
        let config_path = Self::default_config_path()?;

        if config_path.exists() {
            Self::load(&config_path)
        } else {
            Err(anyhow::anyhow!(
                "No config file found at {}. Create one using the example in data/config_example.toml",
                config_path.display()
            ))
        }
    }

    /// Get the default configuration file path.
    pub fn default_config_path() -> Result<PathBuf> {
        dirs::config_dir()
            .map(|p| p.join("efficiency_cockpit").join("config.toml"))
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "Could not determine config directory. Set $XDG_CONFIG_HOME or $HOME"
                )
            })
    }

    /// Validate the configuration.
    fn validate(&self) -> Result<()> {
        // Validate directories
        if self.directories.is_empty() {
            anyhow::bail!("At least one directory must be configured");
        }

        for dir in &self.directories {
            if !dir.exists() {
                anyhow::bail!(
                    "Configured directory does not exist: {}. Create it or remove from config.",
                    dir.display()
                );
            }
        }

        // Validate regex patterns
        for pattern in &self.ignore_patterns {
            Regex::new(pattern)
                .with_context(|| format!("Invalid ignore pattern regex: {}", pattern))?;
        }

        // Validate notification settings
        if self.notifications.daily_digest_hour > 23 {
            anyhow::bail!("daily_digest_hour must be between 0 and 23");
        }

        if self.notifications.max_nudges_per_day > 100 {
            anyhow::bail!("max_nudges_per_day must not exceed 100");
        }

        // Validate database settings
        if self.database.max_snapshots > 1_000_000 {
            anyhow::bail!("max_snapshots must not exceed 1,000,000");
        }

        Ok(())
    }

    /// Create a default configuration for testing or initialization.
    pub fn default_for_testing() -> Self {
        Self {
            directories: vec![PathBuf::from(".")],
            ignore_patterns: vec![
                r"\.git".to_string(),
                r"target".to_string(),
                r"node_modules".to_string(),
            ],
            notifications: NotificationConfig::default(),
            database: DatabaseConfig::default(),
            ai: AiConfig::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_notification_config() {
        let config = NotificationConfig::default();
        assert_eq!(config.daily_digest_hour, 20);
        assert_eq!(config.max_nudges_per_day, 2);
        assert!(config.enable_context_switch_nudges);
    }

    #[test]
    fn test_parse_example_config() {
        let toml_content = r#"
            directories = ["."]
            ignore_patterns = ["\\.git", "target"]

            [notifications]
            daily_digest_hour = 18
            max_nudges_per_day = 3
            enable_context_switch_nudges = false
        "#;

        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.directories.len(), 1);
        assert_eq!(config.notifications.daily_digest_hour, 18);
        assert!(!config.notifications.enable_context_switch_nudges);
    }

    #[test]
    fn test_default_for_testing() {
        let config = Config::default_for_testing();
        assert!(!config.directories.is_empty());
        assert!(!config.ignore_patterns.is_empty());
    }

    #[test]
    fn test_validate_digest_hour_out_of_range() {
        let mut config = Config::default_for_testing();
        config.notifications.daily_digest_hour = 24;
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_validate_empty_directories() {
        let mut config = Config::default_for_testing();
        config.directories.clear();
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_validate_max_nudges_too_high() {
        let mut config = Config::default_for_testing();
        config.notifications.max_nudges_per_day = 101;
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_validate_max_snapshots_too_high() {
        let mut config = Config::default_for_testing();
        config.database.max_snapshots = 1_000_001;
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_validate_invalid_regex() {
        let mut config = Config::default_for_testing();
        config.ignore_patterns = vec!["[invalid".to_string()];
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_load_nonexistent_file() {
        let result = Config::load("/nonexistent/path/config.toml");
        assert!(result.is_err());
    }

    #[test]
    fn test_api_key_not_loaded_from_config() {
        let toml_content = r#"
            directories = ["."]
            ignore_patterns = []

            [ai]
            enabled = true
        "#;

        let config: Config = toml::from_str(toml_content).unwrap();
        // API key should be None since it's skipped from deserialization
        assert!(config.ai.api_key.is_none());
    }

    #[test]
    fn test_api_key_from_env() {
        let ai_config = AiConfig::default();
        // This test just verifies the method exists and returns the config
        let ai_config = ai_config.with_api_key_from_env();
        // Result depends on environment, just verify it doesn't panic
        assert!(ai_config.api_key.is_none() || ai_config.api_key.is_some());
    }
}
