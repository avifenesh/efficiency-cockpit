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
#[command(version, long_version = long_version())]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, global = true)]
    config: Option<PathBuf>,

    /// Enable verbose output
    #[arg(short, long, global = true)]
    verbose: bool,

    /// Quiet mode (minimal output, for scripts)
    #[arg(short, long, global = true)]
    quiet: bool,

    #[command(subcommand)]
    command: Commands,
}

/// Generate long version string with build info.
fn long_version() -> &'static str {
    concat!(
        env!("CARGO_PKG_VERSION"),
        "\n",
        "Build: ",
        env!("CARGO_PKG_NAME"),
        " v",
        env!("CARGO_PKG_VERSION"),
        "\n",
        "Rust edition: 2021"
    )
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

    /// Export snapshots to file (max 10000 when limit=0)
    Export {
        /// Output file path
        #[arg(short, long)]
        output: PathBuf,

        /// Export format (json or csv)
        #[arg(short = 'F', long, default_value = "json")]
        format: String,

        /// Number of snapshots to export (0 = all, max 10000)
        #[arg(short, long, default_value = "0")]
        limit: u32,

        /// Overwrite existing output file
        #[arg(long)]
        force: bool,
    },

    /// Generate shell completions
    Completions {
        /// Shell to generate completions for (bash, zsh, fish, powershell)
        shell: clap_complete::Shell,
    },

    /// Import snapshots from JSON file
    Import {
        /// Input JSON file path
        #[arg(short, long)]
        input: PathBuf,

        /// Skip snapshots that would be duplicates
        #[arg(long)]
        skip_duplicates: bool,
    },

    /// Clean up old snapshots and file events
    Cleanup {
        /// Keep only this many recent snapshots
        #[arg(short, long, default_value = "100")]
        keep: u32,

        /// Actually delete (without this flag, shows what would be deleted)
        #[arg(long)]
        confirm: bool,
    },

    /// Show database statistics
    Stats,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    // Handle completions early (no config/db needed)
    if let Commands::Completions { shell } = cli.command {
        return cmd_completions(shell);
    }

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
        Commands::Export { output, format, limit, force } => cmd_export(&db, &output, &format, limit, force),
        Commands::Completions { .. } => unreachable!(),
        Commands::Import { input, skip_duplicates } => cmd_import(&db, &input, skip_duplicates),
        Commands::Cleanup { keep, confirm } => cmd_cleanup(&db, keep, confirm),
        Commands::Stats => cmd_stats(&db, &config),
    }
}

/// Start the file watcher daemon.
fn cmd_watch(config: &Config, db: &Database) -> Result<()> {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    // Set up graceful shutdown handler
    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();

    ctrlc::set_handler(move || {
        println!("\nShutting down gracefully...");
        r.store(false, Ordering::SeqCst);
    })
    .ok(); // Ignore if handler can't be set

    cli::header("Starting file watcher...");
    cli::info("Watching directories:");
    for dir in &config.directories {
        println!("  - {}", dir.display());
    }
    println!();
    cli::info("Press Ctrl+C to stop.");
    println!();

    let watcher = FileWatcher::new(&config.directories, &config.ignore_patterns)?;
    let snapshot_service = SnapshotService::new(db);
    let mut event_count = 0u64;

    while running.load(Ordering::SeqCst) {
        let events = watcher.wait_for_events(Duration::from_secs(5));

        for event in events {
            let context = context_from_path(&event.path);
            if let Err(e) = snapshot_service.capture(&context, None) {
                tracing::error!("Failed to capture snapshot: {}", e);
            } else {
                event_count += 1;
                tracing::debug!("Captured: {}", event.path.display());
            }
        }

        // Periodic cleanup
        if let Err(e) = snapshot_service.cleanup(config.database.max_snapshots) {
            tracing::warn!("Cleanup failed: {}", e);
        }
    }

    cli::success(&format!("Watcher stopped. Captured {} events.", event_count));
    Ok(())
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
        cli::info("No snapshots found.");
        return Ok(());
    }

    cli::header(&format!("Recent snapshots (showing {}):", snapshots.len()));
    println!();
    for snapshot in &snapshots {
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

    // Hint if at limit
    if snapshots.len() as u32 == limit {
        println!();
        cli::info(&format!("Showing {} snapshots. Use --limit N for more.", limit));
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
fn cmd_export(db: &Database, output: &PathBuf, format: &str, limit: u32, force: bool) -> Result<()> {
    use std::io::Write;

    // Check if file exists and warn if not using --force
    if output.exists() && !force {
        cli::error(&format!(
            "Output file '{}' already exists. Use --force to overwrite.",
            output.display()
        ));
        return Ok(());
    }

    // Limit of 0 means "all", capped at 10000 for safety
    const MAX_EXPORT_LIMIT: u32 = 10000;
    let actual_limit = if limit == 0 { MAX_EXPORT_LIMIT } else { limit };
    let snapshots = db.get_recent_snapshots(actual_limit)?;

    if snapshots.is_empty() {
        cli::warning("No snapshots to export.");
        return Ok(());
    }

    // Warn if export was truncated
    if limit == 0 && snapshots.len() as u32 == MAX_EXPORT_LIMIT {
        cli::warning(&format!(
            "Export limited to {} snapshots. Use --limit to export a specific number.",
            MAX_EXPORT_LIMIT
        ));
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
                    csv_escape(&s.id),
                    csv_escape(&s.timestamp.to_rfc3339()),
                    csv_escape(s.active_file.as_deref().unwrap_or("")),
                    csv_escape(s.active_directory.as_deref().unwrap_or("")),
                    csv_escape(s.git_branch.as_deref().unwrap_or("")),
                    csv_escape(s.notes.as_deref().unwrap_or(""))
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

/// Escape a value for CSV according to RFC 4180.
/// Also sanitizes formula injection characters.
fn csv_escape(value: &str) -> String {
    // Sanitize formula injection - prefix dangerous characters with a single quote
    let sanitized = if value.starts_with('=')
        || value.starts_with('+')
        || value.starts_with('-')
        || value.starts_with('@')
        || value.starts_with('\t')
        || value.starts_with('\r')
    {
        format!("'{}", value)
    } else {
        value.to_string()
    };

    // Check if quoting is needed (contains special characters)
    if sanitized.contains(',')
        || sanitized.contains('"')
        || sanitized.contains('\n')
        || sanitized.contains('\r')
    {
        // Escape double quotes by doubling them and wrap in quotes
        format!("\"{}\"", sanitized.replace('"', "\"\""))
    } else {
        sanitized
    }
}

/// Generate shell completions.
fn cmd_completions(shell: clap_complete::Shell) -> Result<()> {
    use clap::CommandFactory;
    use clap_complete::generate;
    use std::io;

    let mut cmd = Cli::command();
    generate(shell, &mut cmd, "efficiency-cockpit", &mut io::stdout());

    Ok(())
}

/// Import snapshots from JSON file.
fn cmd_import(db: &Database, input: &PathBuf, skip_duplicates: bool) -> Result<()> {
    use efficiency_cockpit::db::Snapshot;

    if !input.exists() {
        cli::error(&format!("Input file not found: {}", input.display()));
        return Ok(());
    }

    let content = std::fs::read_to_string(input)
        .with_context(|| format!("Failed to read input file: {}", input.display()))?;

    let snapshots: Vec<Snapshot> = serde_json::from_str(&content)
        .context("Failed to parse JSON. Ensure the file was exported from efficiency-cockpit.")?;

    if snapshots.is_empty() {
        cli::warning("No snapshots found in input file.");
        return Ok(());
    }

    let existing_ids: std::collections::HashSet<String> = if skip_duplicates {
        db.get_recent_snapshots(10000)?
            .into_iter()
            .map(|s| s.id)
            .collect()
    } else {
        std::collections::HashSet::new()
    };

    let mut imported = 0;
    let mut skipped = 0;

    for snapshot in snapshots {
        if skip_duplicates && existing_ids.contains(&snapshot.id) {
            skipped += 1;
            continue;
        }

        if let Err(e) = db.insert_snapshot(&snapshot) {
            tracing::warn!("Failed to import snapshot {}: {}", &snapshot.id[..8], e);
            skipped += 1;
        } else {
            imported += 1;
        }
    }

    cli::success(&format!("Imported {} snapshots", imported));
    if skipped > 0 {
        cli::info(&format!("Skipped {} snapshots (duplicates or errors)", skipped));
    }

    Ok(())
}

/// Clean up old snapshots and file events.
fn cmd_cleanup(db: &Database, keep: u32, confirm: bool) -> Result<()> {
    let total_snapshots = db.get_recent_snapshots(100000)?.len();

    if total_snapshots as u32 <= keep {
        cli::success(&format!(
            "Nothing to clean up. Currently have {} snapshots (keeping {})",
            total_snapshots, keep
        ));
        return Ok(());
    }

    let to_delete = total_snapshots as u32 - keep;

    if !confirm {
        cli::warning(&format!(
            "Would delete {} snapshots (keeping {} most recent)",
            to_delete, keep
        ));
        cli::info("Run with --confirm to actually delete.");
        return Ok(());
    }

    let deleted = db.cleanup_old_snapshots(keep)?;
    cli::success(&format!(
        "Deleted {} old snapshots. {} remaining.",
        deleted, keep
    ));

    Ok(())
}

/// Show database statistics.
fn cmd_stats(db: &Database, config: &Config) -> Result<()> {
    use chrono::{Duration, Utc};

    cli::header("Efficiency Cockpit Statistics");
    println!();

    // Snapshot stats
    let all_snapshots = db.get_recent_snapshots(100000)?;
    let total_snapshots = all_snapshots.len();

    cli::header("Snapshots:");
    cli::key_value("Total snapshots", &total_snapshots.to_string());

    if !all_snapshots.is_empty() {
        let oldest = all_snapshots.last().map(|s| format_relative_time(s.timestamp));
        let newest = all_snapshots.first().map(|s| format_relative_time(s.timestamp));

        if let Some(oldest) = oldest {
            cli::key_value("Oldest snapshot", &oldest);
        }
        if let Some(newest) = newest {
            cli::key_value("Newest snapshot", &newest);
        }

        // Count snapshots by time period
        let now = Utc::now();
        let today = all_snapshots
            .iter()
            .filter(|s| now - s.timestamp < Duration::days(1))
            .count();
        let this_week = all_snapshots
            .iter()
            .filter(|s| now - s.timestamp < Duration::days(7))
            .count();

        cli::key_value("Snapshots today", &today.to_string());
        cli::key_value("Snapshots this week", &this_week.to_string());
    }

    // File events
    println!();
    cli::header("File Events:");
    let now = Utc::now();
    let events_today = db.get_file_events(now - Duration::days(1), now)?;
    let events_week = db.get_file_events(now - Duration::days(7), now)?;

    cli::key_value("Events today", &events_today.len().to_string());
    cli::key_value("Events this week", &events_week.len().to_string());

    // Database file size
    println!();
    cli::header("Storage:");
    if let Ok(metadata) = std::fs::metadata(&config.database.path) {
        let size_kb = metadata.len() / 1024;
        let size_str = if size_kb > 1024 {
            format!("{:.1} MB", size_kb as f64 / 1024.0)
        } else {
            format!("{} KB", size_kb)
        };
        cli::key_value("Database size", &size_str);
    }
    cli::key_value("Database path", &config.database.path.display().to_string());

    // Search index
    let index_path = config
        .database
        .path
        .parent()
        .unwrap_or(&config.database.path)
        .join("search_index");
    if index_path.exists() {
        if let Ok(size) = dir_size(&index_path) {
            let size_str = if size > 1024 * 1024 {
                format!("{:.1} MB", size as f64 / (1024.0 * 1024.0))
            } else {
                format!("{} KB", size / 1024)
            };
            cli::key_value("Search index size", &size_str);
        }
    } else {
        cli::key_value("Search index", "not created");
    }

    Ok(())
}

/// Calculate total size of a directory.
fn dir_size(path: &std::path::Path) -> std::io::Result<u64> {
    let mut total = 0;
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        if metadata.is_file() {
            total += metadata.len();
        } else if metadata.is_dir() {
            total += dir_size(&entry.path())?;
        }
    }
    Ok(total)
}
