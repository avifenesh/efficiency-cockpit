//! Efficiency Cockpit - A personal productivity tool.
//!
//! This library provides modules for context capture, search,
//! AI-assisted insights, and decision support.

pub mod ai;
pub mod cli;
pub mod config;
pub mod db;
pub mod error;
pub mod gatekeeper;
pub mod search;
pub mod snapshot;
pub mod utils;
pub mod watcher;

pub use error::{ConfigError, DatabaseError, Error, Result, SearchError, WatcherError};
