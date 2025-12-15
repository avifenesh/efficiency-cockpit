//! Efficiency Cockpit - Personal productivity tool
//!
//! A CLI tool for context capture, search, and AI-assisted insights.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

use efficiency_cockpit::{
    cli,
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

    /// Index files for search
    Index {
        /// Directory to index
        #[arg(default_value = ".")]
        path: PathBuf,

        /// Only show what would be indexed (dry run)
        #[arg(short, long)]
        dry_run: bool,
    },

    /// Initialize configuration file
    Init,

    /// Export snapshots to file
    Export {
        /// Output file path
        #[arg(short, long)]
        output: PathBuf,

        /// Export format (json or csv)
        #[arg(short, long, default_value = "json")]
        format: String,

        /// Number of snapshots to export (0 = all)
        #[arg(short, long, default_value = "0")]
        limit: u32,
    },
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
        Commands::Index { path, dry_run } => cmd_index(&config, &path, dry_run),
        Commands::Init => cmd_init(),
        Commands::Export { output, format, limit } => cmd_export(&db, &output, &format, limit),
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

    cli::success("Snapshot captured:");
    cli::key_value("ID", &snapshot.id);
    cli::key_value("Time", &format_local_time(snapshot.timestamp));

    if let Some(ref file) = snapshot.active_file {
        cli::key_value("File", file);
    }
    if let Some(ref dir) = snapshot.active_directory {
        cli::key_value("Directory", dir);
    }
    if let Some(ref branch) = snapshot.git_branch {
        cli::key_value("Git branch", branch);
    }
    if let Some(ref notes) = snapshot.notes {
        cli::key_value("Note", notes);
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
        cli::success("No nudges right now. Keep up the good work!");
        return Ok(());
    }

    cli::header("Nudges & Suggestions:");
    println!();
    for nudge in nudges {
        let priority = match nudge.priority {
            efficiency_cockpit::gatekeeper::NudgePriority::High => "HIGH",
            efficiency_cockpit::gatekeeper::NudgePriority::Medium => "MEDIUM",
            efficiency_cockpit::gatekeeper::NudgePriority::Low => "LOW",
        };
        println!("  {} {}", cli::priority_badge(priority), nudge.message);
    }

    Ok(())
}

/// Show status information.
fn cmd_status(config: &Config, db: &Database) -> Result<()> {
    cli::header("Efficiency Cockpit Status");
    println!();

    // Config status
    cli::header("Configuration:");
    match Config::default_config_path() {
        Ok(path) => {
            if path.exists() {
                cli::key_value("Config file", &format!("{} (found)", path.display()));
            } else {
                cli::key_value("Config file", &format!("{} (not found, using defaults)", path.display()));
            }
        }
        Err(_) => cli::key_value("Config file", "using defaults"),
    }

    cli::key_value("Watched directories", &config.directories.len().to_string());
    for dir in &config.directories {
        cli::status(&dir.display().to_string(), dir.exists());
    }

    // Database status
    println!();
    cli::header("Database:");
    cli::key_value("Path", &config.database.path.display().to_string());

    let snapshot_count = db.get_recent_snapshots(1000)?.len();
    cli::key_value("Snapshots", &snapshot_count.to_string());

    // Notification settings
    println!();
    cli::header("Notifications:");
    cli::key_value("Daily digest hour", &format!("{}:00", config.notifications.daily_digest_hour));
    cli::key_value("Max nudges per day", &config.notifications.max_nudges_per_day.to_string());
    cli::key_value(
        "Context switch nudges",
        if config.notifications.enable_context_switch_nudges {
            "enabled"
        } else {
            "disabled"
        },
    );

    Ok(())
}

/// Index files for search.
fn cmd_index(config: &Config, path: &PathBuf, dry_run: bool) -> Result<()> {
    use walkdir::WalkDir;

    let index_path = config
        .database
        .path
        .parent()
        .unwrap_or(&config.database.path)
        .join("search_index");

    println!("Indexing files from: {}", path.display());
    if dry_run {
        println!("(Dry run - no changes will be made)\n");
    } else {
        println!("Index location: {}\n", index_path.display());
    }

    let mut indexed_count = 0;
    let mut skipped_count = 0;
    let mut docs_to_index = Vec::new();

    // Collect files to index
    for entry in WalkDir::new(path)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let file_path = entry.path();

        // Skip directories
        if file_path.is_dir() {
            continue;
        }

        // Check ignore patterns
        let path_str = file_path.to_string_lossy();
        let should_ignore = config
            .ignore_patterns
            .iter()
            .any(|pattern| path_str.contains(pattern));

        if should_ignore {
            skipped_count += 1;
            continue;
        }

        // Try to read as text
        if let Some(doc) = efficiency_cockpit::search::read_file_for_indexing(file_path) {
            if dry_run {
                println!("  Would index: {}", doc.path);
            } else {
                println!("  Indexing: {}", doc.title);
            }
            indexed_count += 1;
            docs_to_index.push(doc);
        } else {
            skipped_count += 1;
        }
    }

    // Batch write to index
    if !dry_run && !docs_to_index.is_empty() {
        let index = SearchIndex::create_or_open(&index_path)?;
        let mut writer = index.writer()?;
        writer.add_documents(&docs_to_index)?;
        writer.commit()?;
    }

    println!("\nSummary:");
    println!("  Files indexed: {}", indexed_count);
    println!("  Files skipped: {}", skipped_count);

    if dry_run {
        println!("\nRun without --dry-run to actually index files.");
    }

    Ok(())
}

/// Initialize configuration file.
fn cmd_init() -> Result<()> {
    let config_path = Config::default_config_path()?;

    if config_path.exists() {
        println!("Configuration file already exists at:");
        println!("  {}", config_path.display());
        println!("\nEdit this file to customize settings.");
        return Ok(());
    }

    // Create config directory
    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Write default config
    let default_config = r#"# Efficiency Cockpit Configuration

# Directories to watch for file changes
directories = [
    "~/workspace",
    "~/projects"
]

# Patterns to ignore (regex)
ignore_patterns = [
    "\\.git",
    "target",
    "node_modules",
    "__pycache__",
    "\\.cache"
]

[notifications]
# Hour of day (0-23) to send daily digest
daily_digest_hour = 20

# Maximum productivity nudges per day
max_nudges_per_day = 2

# Enable context switch warnings
enable_context_switch_nudges = true

[database]
# Maximum snapshots to retain
max_snapshots = 1000

[ai]
# Enable AI-powered insights (requires API key in EFFICIENCY_COCKPIT_AI_KEY env var)
enabled = false
"#;

    std::fs::write(&config_path, default_config)?;

    println!("Configuration file created at:");
    println!("  {}", config_path.display());
    println!("\nEdit this file to customize your settings, then run:");
    println!("  efficiency-cockpit status");

    Ok(())
}

/// Export snapshots to file (JSON or CSV).
fn cmd_export(db: &Database, output: &PathBuf, format: &str, limit: u32) -> Result<()> {
    use std::io::Write;

    let actual_limit = if limit == 0 { 10000 } else { limit };
    let snapshots = db.get_recent_snapshots(actual_limit)?;

    if snapshots.is_empty() {
        cli::warning("No snapshots to export.");
        return Ok(());
    }

    let content = match format.to_lowercase().as_str() {
        "json" => {
            serde_json::to_string_pretty(&snapshots)
                .context("Failed to serialize snapshots to JSON")?
        }
        "csv" => {
            let mut csv = String::new();
            csv.push_str("id,timestamp,active_file,active_directory,git_branch,notes\n");
            for s in &snapshots {
                csv.push_str(&format!(
                    "{},{},{},{},{},{}\n",
                    s.id,
                    s.timestamp.to_rfc3339(),
                    s.active_file.as_deref().unwrap_or(""),
                    s.active_directory.as_deref().unwrap_or(""),
                    s.git_branch.as_deref().unwrap_or(""),
                    s.notes.as_deref().unwrap_or("").replace(',', ";").replace('\n', " ")
                ));
            }
            csv
        }
        _ => {
            cli::error(&format!("Unknown format '{}'. Use 'json' or 'csv'.", format));
            return Ok(());
        }
    };

    let mut file = std::fs::File::create(output)
        .with_context(|| format!("Failed to create output file: {}", output.display()))?;
    file.write_all(content.as_bytes())?;

    cli::success(&format!(
        "Exported {} snapshots to {} ({})",
        snapshots.len(),
        output.display(),
        format
    ));

    Ok(())
}
