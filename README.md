# Efficiency Cockpit

A native macOS menu bar app for **passive developer productivity tracking** with AI integration via MCP (Model Context Protocol) for Claude Code.

## Features

- **Passive Activity Tracking** - Automatically tracks your work without interrupting your flow
  - App switches and window focus changes
  - Browser navigation (Chrome, Safari, Arc, Firefox, Brave, Edge)
  - IDE file tracking (VS Code, Cursor, Xcode, JetBrains IDEs, Sublime, Zed)
  - Terminal commands (Terminal, iTerm2, Warp, Kitty, Alacritty)
  - Git commits and branch switches
  - AI tool usage detection (Claude, ChatGPT, Copilot, etc.)

- **MCP Server Integration** - Query your productivity data directly from Claude Code
  - `get_current_activity` - What you're working on right now
  - `get_today_activities` - All activities from today
  - `get_time_on_project` - Time spent on specific projects
  - `search_activities` - Search by keyword, app, or project
  - `get_productivity_score` - Calculate productivity metrics

- **Built-in "Ask Claude"** - Chat with Claude about your productivity directly from the app

- **Dashboard Views**
  - Activity Feed - Real-time list of tracked activities
  - Time Tracking - Visual breakdown of time by app
  - Trends - Activity patterns and statistics
  - Projects - Detected projects and activity counts

## Requirements

- macOS 14.0 (Sonoma) or later
- Accessibility permission (for window tracking)
- Automation permission (for browser tab tracking)
- Claude Code CLI (for "Ask Claude" feature)

## Installation

### Build from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/efficiency-cockpit.git
cd efficiency-cockpit

# Build with Swift Package Manager
swift build -c release

# Create app bundle
make app

# The app will be at ~/Applications/Efficiency Cockpit.app
```

### Configure MCP for Claude Code

Add to your `~/.mcp.json`:

```json
{
  "mcpServers": {
    "efficiency-cockpit": {
      "command": "~/Applications/Efficiency Cockpit.app/Contents/MacOS/EfficiencyCockpitMCPServer",
      "args": []
    }
  }
}
```

Enable in `~/.claude/settings.json`:

```json
{
  "enabledMcpjsonServers": ["efficiency-cockpit"]
}
```

## Project Structure

```
EfficiencyCockpit/
├── App/                       # App entry point and state
├── Core/
│   ├── Models/               # SwiftData models
│   │   ├── Activity.swift
│   │   ├── AppSession.swift
│   │   ├── ProductivityInsight.swift
│   │   └── DailySummary.swift
│   └── Services/
│       ├── ActivityTracker/  # Tracking services
│       │   ├── ActivityTrackingService.swift
│       │   ├── WindowTracker.swift
│       │   ├── BrowserTabTracker.swift
│       │   ├── IDEFileTracker.swift
│       │   ├── GitActivityTracker.swift
│       │   └── AIToolUsageTracker.swift
│       ├── Permissions/      # macOS permissions
│       └── ClaudeService.swift
└── UI/
    ├── MenuBar/              # Menu bar interface
    ├── Dashboard/            # Main dashboard
    ├── Settings/             # Settings views
    └── Onboarding/           # First-run experience

EfficiencyCockpitMCPServer/   # Standalone MCP server
├── main.swift
└── DataAccess.swift
```

## Usage

1. **Launch the app** - It appears in your menu bar
2. **Grant permissions** - Allow Accessibility and Automation access when prompted
3. **Start tracking** - Toggle tracking on from the menu bar
4. **View dashboard** - Click the menu bar icon to open the dashboard
5. **Ask Claude** - Use the built-in chat to ask about your productivity

### Example Claude Queries

- "What have I been working on today?"
- "How much time did I spend in VS Code?"
- "Which project took most of my time this week?"
- "Give me insights about my work patterns"

## Privacy

All data is stored locally on your Mac using SwiftData. No data is sent to external servers except when using the "Ask Claude" feature, which sends activity summaries to Claude via the CLI.

## Development

```bash
# Build debug version
swift build

# Run tests
swift test

# Build release
swift build -c release

# Create app bundle
make app
```

## License

MIT License - see LICENSE file for details.
