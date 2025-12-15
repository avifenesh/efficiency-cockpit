import SwiftUI

struct SettingsView: View {
    private enum Tabs: Hashable {
        case general, permissions, tracking, mcp, about
    }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(Tabs.general)

            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
                .tag(Tabs.permissions)

            TrackingSettingsView()
                .tabItem {
                    Label("Tracking", systemImage: "eye")
                }
                .tag(Tabs.tracking)

            MCPSettingsView()
                .tabItem {
                    Label("MCP", systemImage: "server.rack")
                }
                .tag(Tabs.mcp)

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(Tabs.about)
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("enableNotifications") private var enableNotifications = true

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)
                Toggle("Enable Notifications", isOn: $enableNotifications)
            } header: {
                Text("General")
            }

            Section {
                LabeledContent("Data Location") {
                    Text(dataLocation)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Button("Open Data Folder") {
                    openDataFolder()
                }
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var dataLocation: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return appSupport?.appendingPathComponent("EfficiencyCockpit").path ?? "Unknown"
    }

    private func openDataFolder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let folder = appSupport?.appendingPathComponent("EfficiencyCockpit") {
            NSWorkspace.shared.open(folder)
        }
    }
}

// MARK: - Permissions Settings

struct PermissionsSettingsView: View {
    @StateObject private var permissionManager = PermissionManager()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Accessibility",
                    description: "Required to track active windows and applications",
                    status: permissionManager.accessibilityStatus,
                    action: {
                        _ = permissionManager.requestAccessibilityPermission()
                    },
                    openSettings: {
                        permissionManager.openSystemPreferences(for: .accessibility)
                    }
                )

                PermissionRow(
                    title: "Screen Recording",
                    description: "Required to see window titles (files, tabs, projects)",
                    status: permissionManager.screenRecordingStatus,
                    action: nil,
                    openSettings: {
                        permissionManager.openSystemPreferences(for: .screenRecording)
                    }
                )

                PermissionRow(
                    title: "Full Disk Access",
                    description: "Required to read shell history and git directories",
                    status: permissionManager.fullDiskAccessStatus,
                    action: nil,
                    openSettings: {
                        permissionManager.openSystemPreferences(for: .fullDiskAccess)
                    }
                )
            } header: {
                Text("Required Permissions")
            } footer: {
                Text("Grant these permissions to enable full tracking capabilities. Screen Recording is essential for tracking files and projects.")
            }

            Section {
                ForEach(Array(PermissionManager.trackedApps.keys.sorted()), id: \.self) { bundleId in
                    let appName = PermissionManager.trackedApps[bundleId] ?? bundleId
                    let status = permissionManager.automationStatus[bundleId] ?? .unknown

                    PermissionRow(
                        title: appName,
                        description: "Enable AppleScript access",
                        status: status,
                        action: {
                            Task {
                                await permissionManager.requestAutomationPermission(for: bundleId)
                            }
                        },
                        openSettings: {
                            permissionManager.openSystemPreferences(for: .automation)
                        }
                    )
                }
            } header: {
                Text("Automation Permissions")
            } footer: {
                Text("Automation permissions allow reading browser tabs and IDE contexts.")
            }

            Section {
                HStack {
                    Text("Tracking Capability")
                    Spacer()
                    Text(permissionManager.trackingCapability.description)
                        .foregroundColor(capabilityColor)
                        .fontWeight(.medium)
                }
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            permissionManager.checkAllPermissions()
        }
    }

    private var capabilityColor: Color {
        switch permissionManager.trackingCapability {
        case .full: return .green
        case .limited: return .orange
        case .minimal: return .red
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let status: PermissionStatus
    let action: (() -> Void)?
    let openSettings: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            StatusBadge(status: status)

            if status != .granted {
                if let action = action {
                    Button("Request") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Open Settings") {
                        openSettings()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let status: PermissionStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(status.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.1))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .restricted: return .orange
        case .unknown: return .gray
        }
    }
}

// MARK: - Tracking Settings

struct TrackingSettingsView: View {
    @AppStorage("pollingInterval") private var pollingInterval: Double = 5.0
    @AppStorage("trackBrowserTabs") private var trackBrowserTabs = true
    @AppStorage("trackIDEFiles") private var trackIDEFiles = true
    @AppStorage("trackTerminalCommands") private var trackTerminalCommands = true
    @AppStorage("trackGitActivity") private var trackGitActivity = true
    @AppStorage("trackAITools") private var trackAITools = true
    @AppStorage("dataRetentionDays") private var dataRetentionDays: Int = 30

    var body: some View {
        Form {
            Section {
                Picker("Polling Interval", selection: $pollingInterval) {
                    Text("1 second").tag(1.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds (Default)").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Performance")
            } footer: {
                Text("Shorter intervals provide more accurate tracking but use more battery.")
            }

            Section {
                Toggle("Browser Tabs", isOn: $trackBrowserTabs)
                Toggle("IDE/Editor Files", isOn: $trackIDEFiles)
                Toggle("Terminal Commands", isOn: $trackTerminalCommands)
                Toggle("Git Activity", isOn: $trackGitActivity)
                Toggle("AI Tools (Claude, ChatGPT, etc.)", isOn: $trackAITools)
            } header: {
                Text("What to Track")
            }

            Section {
                Picker("Keep data for", selection: $dataRetentionDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days (Default)").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Forever").tag(0)
                }
                .pickerStyle(.menu)

                Button("Clear All Data", role: .destructive) {
                    // TODO: Implement data clearing
                }
            } header: {
                Text("Data Retention")
            } footer: {
                Text("Older data will be automatically deleted to save space.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - MCP Settings

struct MCPSettingsView: View {
    @AppStorage("mcpServerEnabled") private var mcpServerEnabled = true
    @AppStorage("mcpServerPort") private var mcpServerPort: Int = 0

    var body: some View {
        Form {
            Section {
                Toggle("Enable MCP Server", isOn: $mcpServerEnabled)
            } header: {
                Text("Model Context Protocol")
            } footer: {
                Text("Enable to allow Claude Code and other AI tools to access your activity data.")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add to Claude Code settings:")
                        .fontWeight(.medium)

                    Text(mcpConfigSnippet)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                        .textSelection(.enabled)

                    Button("Copy Configuration") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpConfigSnippet, forType: .string)
                    }
                }
            } header: {
                Text("Integration")
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(mcpServerEnabled ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(mcpServerEnabled ? "Running" : "Stopped")
                            .foregroundColor(.secondary)
                    }
                }

                LabeledContent("Transport") {
                    Text("stdio")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Server Status")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var mcpConfigSnippet: String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return """
        {
          "mcpServers": {
            "efficiency-cockpit": {
              "command": "\(homeDir)/Applications/Efficiency Cockpit.app/Contents/MacOS/EfficiencyCockpitMCPServer"
            }
          }
        }
        """
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Efficiency Cockpit")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .foregroundColor(.secondary)

            Text("Passive productivity tracking for developers")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            VStack(spacing: 8) {
                Link("View on GitHub", destination: URL(string: "https://github.com/avifenesh/efficiency-cockpit")!)

                Link("Report an Issue", destination: URL(string: "https://github.com/avifenesh/efficiency-cockpit/issues")!)
            }

            Spacer()

            Text("Made with SwiftUI")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    SettingsView()
}
