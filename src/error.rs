//! Custom error types for Efficiency Cockpit.
//!
//! This module provides structured error types for better error handling
//! and more informative error messages.

use std::path::PathBuf;
use thiserror::Error;

/// Main error type for Efficiency Cockpit operations.
#[derive(Error, Debug)]
pub enum Error {
    /// Configuration-related errors
    #[error(transparent)]
    Config(#[from] ConfigError),

    /// Database-related errors
    #[error(transparent)]
    Database(#[from] DatabaseError),

    /// Search index errors
    #[error(transparent)]
    Search(#[from] SearchError),

    /// File watcher errors
    #[error(transparent)]
    Watcher(#[from] WatcherError),

    /// IO errors
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Configuration-related errors.
#[derive(Error, Debug)]
pub enum ConfigError {
    /// Config file not found
    #[error("Configuration file not found at: {path}")]
    NotFound { path: PathBuf },

    /// Failed to parse config file
    #[error("Failed to parse configuration: {message}")]
    ParseError { message: String },

    /// Invalid configuration value
    #[error("Invalid configuration value for '{field}': {message}")]
    InvalidValue { field: String, message: String },

    /// Invalid regex pattern in ignore_patterns
    #[error("Invalid regex pattern '{pattern}': {message}")]
    InvalidPattern { pattern: String, message: String },

    /// Failed to determine config directory
    #[error("Could not determine configuration directory")]
    NoConfigDir,

    /// IO error during config operations
    #[error("Configuration IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Database-related errors.
#[derive(Error, Debug)]
pub enum DatabaseError {
    /// Failed to open database
    #[error("Failed to open database at {path}: {message}")]
    OpenFailed { path: PathBuf, message: String },

    /// Query execution failed
    #[error("Database query failed: {message}")]
    QueryFailed { message: String },

    /// Data serialization/deserialization error
    #[error("Data serialization error: {message}")]
    SerializationError { message: String },

    /// SQLite error
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
}

/// Search index errors.
#[derive(Error, Debug)]
pub enum SearchError {
    /// Failed to create index
    #[error("Failed to create search index at {path}: {message}")]
    CreateFailed { path: PathBuf, message: String },

    /// Failed to open existing index
    #[error("Failed to open search index at {path}: {message}")]
    OpenFailed { path: PathBuf, message: String },

    /// Query parsing error
    #[error("Invalid search query '{query}': {message}")]
    InvalidQuery { query: String, message: String },

    /// Indexing error
    #[error("Failed to index document: {message}")]
    IndexingFailed { message: String },

    /// Tantivy error
    #[error("Search engine error: {0}")]
    Tantivy(#[from] tantivy::TantivyError),
}

/// File watcher errors.
#[derive(Error, Debug)]
pub enum WatcherError {
    /// Failed to watch directory
    #[error("Failed to watch directory {path}: {message}")]
    WatchFailed { path: PathBuf, message: String },

    /// Directory not found
    #[error("Directory not found: {path}")]
    DirectoryNotFound { path: PathBuf },

    /// Invalid ignore pattern
    #[error("Invalid ignore pattern '{pattern}': {message}")]
    InvalidPattern { pattern: String, message: String },

    /// Notify error
    #[error("File watcher error: {0}")]
    Notify(#[from] notify::Error),
}

/// Result type alias using our Error type.
pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_error_display() {
        let err = ConfigError::NotFound {
            path: PathBuf::from("/path/to/config.toml"),
        };
        assert!(err.to_string().contains("/path/to/config.toml"));
    }

    #[test]
    fn test_database_error_display() {
        let err = DatabaseError::OpenFailed {
            path: PathBuf::from("/path/to/db"),
            message: "permission denied".to_string(),
        };
        assert!(err.to_string().contains("permission denied"));
    }

    #[test]
    fn test_search_error_display() {
        let err = SearchError::InvalidQuery {
            query: "bad query".to_string(),
            message: "syntax error".to_string(),
        };
        assert!(err.to_string().contains("bad query"));
    }

    #[test]
    fn test_watcher_error_display() {
        let err = WatcherError::DirectoryNotFound {
            path: PathBuf::from("/nonexistent"),
        };
        assert!(err.to_string().contains("/nonexistent"));
    }

    #[test]
    fn test_error_conversion() {
        let config_err = ConfigError::NoConfigDir;
        let main_err: Error = config_err.into();
        assert!(main_err.to_string().contains("configuration directory"));
    }
}
