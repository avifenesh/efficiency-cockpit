# Efficiency Cockpit

A personal productivity CLI tool for context capture, search, and AI-assisted insights.

## Features

- **File Watching**: Monitor directories for changes and automatically capture context
- **Context Snapshots**: Capture work context including active files, directories, and git branches
- **Full-Text Search**: Index and search your files using Tantivy
- **Productivity Nudges**: Get suggestions based on activity patterns
- **Daily Summaries**: Track your work activity over time
- **AI Insights**: Rule-based (and optionally AI-powered) productivity insights

## Installation

```bash
# Build from source
cargo build --release

# The binary will be at target/release/efficiency_cockpit
```

## Quick Start

```bash
# Initialize configuration
efficiency-cockpit init

# Edit the generated config file to add your directories
# Then check status
efficiency-cockpit status

# Capture a snapshot
efficiency-cockpit snapshot --note "Working on feature X"

# Start the file watcher
efficiency-cockpit watch
```

## Commands

### `init`
Create a default configuration file.

```bash
efficiency-cockpit init
```

### `status`
Show current status and configuration.

```bash
efficiency-cockpit status
```

### `snapshot`
Capture a snapshot of current context.

```bash
efficiency-cockpit snapshot [PATH] --note "Optional note"
```

### `list`
List recent snapshots.

```bash
efficiency-cockpit list --limit 20
```

### `watch`
Start the file watcher daemon.

```bash
efficiency-cockpit watch
```

### `index`
Index files for search.

```bash
# Preview what would be indexed
efficiency-cockpit index --dry-run ./src

# Actually index the files
efficiency-cockpit index ./src
```

### `search`
Search indexed content.

```bash
efficiency-cockpit search "query string" --limit 10
```

### `summary`
Show daily activity summary.

```bash
efficiency-cockpit summary
```

### `nudge`
Get productivity nudges and suggestions.

```bash
efficiency-cockpit nudge
```

### `export`
Export snapshots to JSON or CSV file.

```bash
# Export to JSON (default)
efficiency-cockpit export --output snapshots.json

# Export to CSV
efficiency-cockpit export --output snapshots.csv --format csv

# Limit number of snapshots
efficiency-cockpit export --output recent.json --limit 50
```

### `completions`
Generate shell completions for bash, zsh, fish, or PowerShell.

```bash
# Bash
efficiency-cockpit completions bash > ~/.bash_completion.d/efficiency-cockpit

# Zsh
efficiency-cockpit completions zsh > ~/.zfunc/_efficiency-cockpit

# Fish
efficiency-cockpit completions fish > ~/.config/fish/completions/efficiency-cockpit.fish
```

### `import`
Import snapshots from a JSON file (exported with `export`).

```bash
# Import all snapshots
efficiency-cockpit import --input snapshots.json

# Skip duplicates (by ID)
efficiency-cockpit import --input snapshots.json --skip-duplicates
```

### `cleanup`
Clean up old snapshots to free disk space.

```bash
# Preview what would be deleted
efficiency-cockpit cleanup --keep 100

# Actually delete (keep 100 most recent)
efficiency-cockpit cleanup --keep 100 --confirm
```

## Configuration

Configuration file location:
- macOS: `~/Library/Application Support/efficiency_cockpit/config.toml`
- Linux: `~/.local/share/efficiency_cockpit/config.toml`

Example configuration:

```toml
# Directories to watch
directories = [
    "~/workspace",
    "~/projects"
]

# Patterns to ignore (regex)
ignore_patterns = [
    "\\.git",
    "target",
    "node_modules"
]

[notifications]
daily_digest_hour = 20
max_nudges_per_day = 2
enable_context_switch_nudges = true

[database]
max_snapshots = 1000

[ai]
enabled = false
```

## Environment Variables

- `EFFICIENCY_COCKPIT_AI_KEY`: API key for AI-powered insights (optional)

## Architecture

```
src/
├── main.rs       # CLI entry point
├── cli.rs        # CLI output helpers (colorization)
├── config.rs     # Configuration management
├── db.rs         # SQLite database layer
├── error.rs      # Custom error types
├── watcher.rs    # File system monitoring
├── snapshot.rs   # Context capture
├── search.rs     # Full-text search (Tantivy)
├── gatekeeper.rs # Nudge/decision support
├── ai.rs         # AI insights
└── utils.rs      # Helper functions
```

## License

MIT
