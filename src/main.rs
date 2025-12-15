//! Efficiency Cockpit - Personal productivity tool
//!
//! A CLI tool for context capture, search, and AI-assisted insights.

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

use efficiency_cockpit::{
    config::Config,
    db::Database,
    gatekeeper::{Gatekeeper, GatekeeperConfig},
    search::SearchIndex,
    snapshot::{context_from_path, SnapshotService},
    utils::{format_local_time, format_relative_time},
    watcher::FileWatcher,
};

/// Efficiency Cockpit - Personal productivity tool
#[derive(Parser)]
#[command(name = "efficiency-cockpit")]
#[command(about = "A personal productivity tool for context capture and insights")]
#[command(version)]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, global = true)]
    config: Option<PathBuf>,

    /// Enable verbose output
    #[arg(short, long, global = true)]
    verbose: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the watcher daemon
    Watch,

    /// Capture a snapshot of current context
    Snapshot {
        /// Path to capture context from
        #[arg(default_value = ".")]
        path: PathBuf,

        /// Optional note to attach
        #[arg(short, long)]
        note: Option<String>,
    },

    /// List recent snapshots
    List {
        /// Number of snapshots to show
        #[arg(short, long, default_value = "10")]
        limit: u32,
    },

    /// Search indexed content
    Search {
        /// Search query
        query: String,

        /// Maximum results to show
        #[arg(short, long, default_value = "10")]
        limit: usize,
    },

    /// Show activity summary
    Summary,

    /// Get nudges and suggestions
    Nudge,

    /// Show status information
    Status,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    // Initialize logging
    let filter = if cli.verbose {
        EnvFilter::new("debug")
    } else {
        EnvFilter::new("info")
    };

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .init();

    // Load configuration
    let config = if let Some(config_path) = cli.config {
        Config::load(&config_path)?
    } else {
        match Config::load_default() {
            Ok(c) => c,
            Err(_) => {
                tracing::warn!("No config file found, using defaults for testing");
                Config::default_for_testing()
            }
        }
    };

    // Open database
    let db = Database::open(&config.database.path)?;

    // Execute command
    match cli.command {
        Commands::Watch => cmd_watch(&config, &db),
        Commands::Snapshot { path, note } => cmd_snapshot(&db, &path, note),
        Commands::List { limit } => cmd_list(&db, limit),
        Commands::Search { query, limit } => cmd_search(&config, &query, limit),
        Commands::Summary => cmd_summary(&db, &config),
        Commands::Nudge => cmd_nudge(&db, &config),
        Commands::Status => cmd_status(&config, &db),
    }
}

/// Start the file watcher daemon.
fn cmd_watch(config: &Config, db: &Database) -> Result<()> {
    use std::time::Duration;

    println!("Starting file watcher...");
    println!("Watching directories:");
    for dir in &config.directories {
        println!("  - {}", dir.display());
    }
    println!("\nPress Ctrl+C to stop.\n");

    let watcher = FileWatcher::new(&config.directories, &config.ignore_patterns)?;
    let snapshot_service = SnapshotService::new(db);

    loop {
        let events = watcher.wait_for_events(Duration::from_secs(5));

        for event in events {
            let context = context_from_path(&event.path);
            if let Err(e) = snapshot_service.capture(&context, None) {
                tracing::error!("Failed to capture snapshot: {}", e);
            } else {
                tracing::debug!("Captured: {}", event.path.display());
            }
        }

        // Periodic cleanup
        if let Err(e) = snapshot_service.cleanup(config.database.max_snapshots) {
            tracing::warn!("Cleanup failed: {}", e);
        }
    }
}

/// Capture a snapshot of current context.
fn cmd_snapshot(db: &Database, path: &PathBuf, note: Option<String>) -> Result<()> {
    let service = SnapshotService::new(db);
    let context = context_from_path(path);

    let snapshot = service.capture(&context, note)?;

    println!("Snapshot captured:");
    println!("  ID: {}", snapshot.id);
    println!("  Time: {}", format_local_time(snapshot.timestamp));

    if let Some(ref file) = snapshot.active_file {
        println!("  File: {}", file);
    }
    if let Some(ref dir) = snapshot.active_directory {
        println!("  Directory: {}", dir);
    }
    if let Some(ref branch) = snapshot.git_branch {
        println!("  Git branch: {}", branch);
    }
    if let Some(ref notes) = snapshot.notes {
        println!("  Note: {}", notes);
    }

    Ok(())
}

/// List recent snapshots.
fn cmd_list(db: &Database, limit: u32) -> Result<()> {
    let service = SnapshotService::new(db);
    let snapshots = service.get_recent(limit)?;

    if snapshots.is_empty() {
        println!("No snapshots found.");
        return Ok(());
    }

    println!("Recent snapshots:\n");
    for snapshot in snapshots {
        println!(
            "  {} | {} | {}",
            &snapshot.id[..8],
            format_relative_time(snapshot.timestamp),
            snapshot.active_directory.as_deref().unwrap_or("-")
        );
        if let Some(ref branch) = snapshot.git_branch {
            println!("       branch: {}", branch);
        }
        if let Some(ref note) = snapshot.notes {
            println!("       note: {}", note);
        }
    }

    Ok(())
}

/// Search indexed content.
fn cmd_search(config: &Config, query: &str, limit: usize) -> Result<()> {
    let index_path = config.database.path.parent().unwrap_or(&config.database.path).join("search_index");

    let index = SearchIndex::create_or_open(&index_path)?;
    let results = index.search(query, limit)?;

    if results.is_empty() {
        println!("No results found for: {}", query);
        return Ok(());
    }

    println!("Search results for '{}':\n", query);
    for result in results {
        println!("  {} (score: {:.2})", result.title, result.score);
        println!("    {}", result.path);
    }

    Ok(())
}

/// Show activity summary.
fn cmd_summary(db: &Database, config: &Config) -> Result<()> {
    let gatekeeper = Gatekeeper::new(
        db,
        GatekeeperConfig {
            max_nudges_per_day: config.notifications.max_nudges_per_day,
            enable_context_switch_nudges: config.notifications.enable_context_switch_nudges,
            ..Default::default()
        },
    );

    let summary = gatekeeper.daily_summary(chrono::Utc::now());

    println!("Daily Summary\n");
    println!("{}", summary.to_message());

    if summary.total_events > 0 {
        println!("\nDetails:");
        println!("  Total events: {}", summary.total_events);
        println!("  Files modified: {}", summary.files_modified);
        println!("  Files created: {}", summary.files_created);
        if let Some(ref dir) = summary.most_active_directory {
            println!("  Most active directory: {}", dir);
        }
    }

    Ok(())
}

/// Get nudges and suggestions.
fn cmd_nudge(db: &Database, config: &Config) -> Result<()> {
    let gatekeeper = Gatekeeper::new(
        db,
        GatekeeperConfig {
            max_nudges_per_day: config.notifications.max_nudges_per_day,
            enable_context_switch_nudges: config.notifications.enable_context_switch_nudges,
            ..Default::default()
        },
    );

    let nudges = gatekeeper.analyze();

    if nudges.is_empty() {
        println!("No nudges right now. Keep up the good work!");
        return Ok(());
    }

    println!("Nudges & Suggestions:\n");
    for nudge in nudges {
        let priority = match nudge.priority {
            efficiency_cockpit::gatekeeper::NudgePriority::High => "[HIGH]",
            efficiency_cockpit::gatekeeper::NudgePriority::Medium => "[MEDIUM]",
            efficiency_cockpit::gatekeeper::NudgePriority::Low => "[LOW]",
        };
        println!("  {} {}", priority, nudge.message);
    }

    Ok(())
}

/// Show status information.
fn cmd_status(config: &Config, db: &Database) -> Result<()> {
    println!("Efficiency Cockpit Status\n");

    // Config status
    println!("Configuration:");
    match Config::default_config_path() {
        Ok(path) => {
            if path.exists() {
                println!("  Config file: {} (found)", path.display());
            } else {
                println!("  Config file: {} (not found, using defaults)", path.display());
            }
        }
        Err(_) => println!("  Config file: using defaults"),
    }

    println!("  Watched directories: {}", config.directories.len());
    for dir in &config.directories {
        let status = if dir.exists() { "OK" } else { "MISSING" };
        println!("    - {} [{}]", dir.display(), status);
    }

    // Database status
    println!("\nDatabase:");
    println!("  Path: {}", config.database.path.display());

    let snapshot_count = db.get_recent_snapshots(1000)?.len();
    println!("  Snapshots: {}", snapshot_count);

    // Notification settings
    println!("\nNotifications:");
    println!(
        "  Daily digest hour: {}:00",
        config.notifications.daily_digest_hour
    );
    println!(
        "  Max nudges per day: {}",
        config.notifications.max_nudges_per_day
    );
    println!(
        "  Context switch nudges: {}",
        if config.notifications.enable_context_switch_nudges {
            "enabled"
        } else {
            "disabled"
        }
    );

    Ok(())
}
