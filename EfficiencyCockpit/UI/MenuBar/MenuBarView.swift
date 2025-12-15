import SwiftUI
import SwiftData

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Activity.timestamp, order: .reverse)
    private var recentActivities: [Activity]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Quick Stats
            quickStatsSection

            Divider()

            // Recent Activity
            recentActivitySection

            Divider()

            // Actions
            actionsSection
        }
        .frame(width: 320)
        .onAppear {
            appState.activityTracker.configure(modelContext: modelContext)
            // Refresh stats when menu opens
            Task {
                await appState.refreshStats()
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Efficiency Cockpit")
                    .font(.headline)

                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.isTracking ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    Text(appState.isTracking ? "Tracking" : "Paused")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { appState.isTracking },
                set: { _ in appState.toggleTracking() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding()
    }

    private var quickStatsSection: some View {
        VStack(spacing: 8) {
            HStack {
                StatItem(
                    icon: "clock",
                    title: "Active Time",
                    value: formatDuration(appState.todayStats.totalActiveTime)
                )

                Spacer()

                StatItem(
                    icon: "eye",
                    title: "Focus Sessions",
                    value: "\(appState.todayStats.focusSessionCount)"
                )

                Spacer()

                StatItem(
                    icon: "arrow.triangle.swap",
                    title: "Switches",
                    value: "\(appState.todayStats.contextSwitchCount)"
                )
            }
        }
        .padding()
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            if recentActivities.isEmpty {
                Text("No activity recorded yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(recentActivities.prefix(5)) { activity in
                    ActivityRowCompact(activity: activity)
                }
            }
        }
        .padding()
    }

    private var actionsSection: some View {
        VStack(spacing: 4) {
            Button(action: { openWindow(id: "dashboard") }) {
                Label("Open Dashboard", systemImage: "chart.bar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)

            SettingsLink {
                Label("Settings...", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Supporting Views

struct StatItem: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)

            Text(value)
                .font(.headline)

            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct ActivityRowCompact: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activity.type.icon)
                .foregroundColor(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.appName ?? "Unknown")
                    .font(.caption)
                    .lineLimit(1)

                if let title = activity.windowTitle {
                    Text(title)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(timeAgo(activity.timestamp))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else {
            return "\(Int(interval / 3600))h ago"
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState.preview)
}
