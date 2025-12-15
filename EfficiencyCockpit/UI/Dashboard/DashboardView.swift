import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab: DashboardTab = .activity

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .navigationTitle("Efficiency Cockpit")
        .onAppear {
            appState.activityTracker.configure(modelContext: modelContext)
        }
    }

    private var sidebarContent: some View {
        List(selection: $selectedTab) {
            Section("Today") {
                Label("Activity Feed", systemImage: "list.bullet")
                    .tag(DashboardTab.activity)

                Label("Time Tracking", systemImage: "clock")
                    .tag(DashboardTab.timeTracking)
            }

            Section("AI") {
                Label("Ask Claude", systemImage: "bubble.left.and.bubble.right")
                    .tag(DashboardTab.askClaude)
            }

            Section("Analytics") {
                Label("Trends", systemImage: "chart.line.uptrend.xyaxis")
                    .tag(DashboardTab.trends)
            }

            Section("Projects") {
                Label("All Projects", systemImage: "folder")
                    .tag(DashboardTab.projects)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .activity:
            ActivityFeedView()
        case .timeTracking:
            TimeTrackingView()
        case .askClaude:
            AskClaudeView()
        case .trends:
            TrendsView()
        case .projects:
            ProjectsView()
        }
    }
}

enum DashboardTab: Hashable {
    case activity
    case timeTracking
    case askClaude
    case trends
    case projects
}

// MARK: - Activity Feed

struct ActivityFeedView: View {
    @Query(sort: \Activity.timestamp, order: .reverse)
    private var activities: [Activity]

    @State private var filterType: ActivityType?

    var body: some View {
        VStack(alignment: .leading) {
            // Filter bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    FilterChip(title: "All", isSelected: filterType == nil) {
                        filterType = nil
                    }

                    ForEach(ActivityType.allCases, id: \.self) { type in
                        FilterChip(title: type.displayName, isSelected: filterType == type) {
                            filterType = type
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)

            // Activity list
            List {
                ForEach(filteredActivities) { activity in
                    ActivityRowView(activity: activity)
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Activity Feed")
    }

    private var filteredActivities: [Activity] {
        if let filter = filterType {
            return activities.filter { $0.type == filter }
        }
        return activities
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

struct ActivityRowView: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.type.icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(activity.appName ?? "Unknown App")
                        .font(.headline)

                    Spacer()

                    Text(activity.timestamp, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let title = activity.windowTitle {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    Label(activity.type.displayName, systemImage: activity.type.icon)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if let duration = activity.duration {
                        Text("• \(formatDuration(duration))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

// MARK: - Placeholder Views

struct TimeTrackingView: View {
    @Query(sort: \Activity.timestamp, order: .reverse)
    private var activities: [Activity]

    var body: some View {
        VStack {
            if activities.isEmpty {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "clock",
                    description: Text("Start tracking to see time data")
                )
            } else {
                Chart(appTimeData, id: \.app) { item in
                    BarMark(
                        x: .value("Time", item.time / 60),
                        y: .value("App", item.app)
                    )
                    .foregroundStyle(by: .value("App", item.app))
                }
                .chartXAxisLabel("Minutes")
                .padding()
            }
        }
        .navigationTitle("Time Tracking")
    }

    private var appTimeData: [(app: String, time: TimeInterval)] {
        var timeByApp: [String: TimeInterval] = [:]

        for activity in activities {
            let appName = activity.appName ?? "Unknown"
            timeByApp[appName, default: 0] += activity.duration ?? 0
        }

        return timeByApp.map { (app: $0.key, time: $0.value) }
            .sorted(by: { $0.time > $1.time })
            .prefix(10)
            .map { $0 }
    }
}

struct InsightsView: View {
    @Query(sort: \ProductivityInsight.generatedAt, order: .reverse)
    private var insights: [ProductivityInsight]

    var body: some View {
        VStack {
            if insights.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "brain")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("AI Insights")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("MCP server is configured. In Claude Code, ask:")
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("• \"What have I been working on today?\"")
                        Text("• \"How productive was I this week?\"")
                        Text("• \"Store an insight about my work patterns\"")
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(insights) { insight in
                        InsightCardView(insight: insight)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("AI Insights")
    }
}

struct InsightCardView: View {
    let insight: ProductivityInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: insight.type.icon)
                    .foregroundColor(.accentColor)

                Text(insight.title)
                    .font(.headline)

                Spacer()

                Text(insight.generatedAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(insight.content)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

struct TrendsView: View {
    @Query(sort: \Activity.timestamp, order: .reverse)
    private var activities: [Activity]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if activities.isEmpty {
                    ContentUnavailableView(
                        "No Data Yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Start tracking to see trends")
                    )
                } else {
                    // Activity by type chart
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Activity by Type")
                            .font(.headline)

                        Chart(activityByType, id: \.type) { item in
                            BarMark(
                                x: .value("Count", item.count),
                                y: .value("Type", item.type)
                            )
                            .foregroundStyle(by: .value("Type", item.type))
                        }
                        .frame(height: 200)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)

                    // Today's summary
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Today's Summary")
                            .font(.headline)

                        HStack(spacing: 20) {
                            StatBox(title: "Activities", value: "\(todayActivities.count)")
                            StatBox(title: "Apps Used", value: "\(uniqueAppsToday)")
                            StatBox(title: "Projects", value: "\(uniqueProjectsToday)")
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)

                    // Top apps
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Apps Today")
                            .font(.headline)

                        ForEach(topAppsToday.prefix(5), id: \.app) { item in
                            HStack {
                                Text(item.app)
                                Spacer()
                                Text("\(item.count) activities")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding()
        }
        .navigationTitle("Trends")
    }

    private var todayActivities: [Activity] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return activities.filter { $0.timestamp >= startOfDay }
    }

    private var uniqueAppsToday: Int {
        Set(todayActivities.compactMap { $0.appName }).count
    }

    private var uniqueProjectsToday: Int {
        Set(todayActivities.compactMap { $0.projectPath }).count
    }

    private var activityByType: [(type: String, count: Int)] {
        var counts: [String: Int] = [:]
        for activity in todayActivities {
            counts[activity.type.displayName, default: 0] += 1
        }
        return counts.map { (type: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var topAppsToday: [(app: String, count: Int)] {
        var counts: [String: Int] = [:]
        for activity in todayActivities {
            if let app = activity.appName {
                counts[app, default: 0] += 1
            }
        }
        return counts.map { (app: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
}

struct StatBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack {
            Text(value)
                .font(.title)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProjectsView: View {
    @Query(sort: \Activity.timestamp, order: .reverse)
    private var activities: [Activity]

    var body: some View {
        VStack {
            if projects.isEmpty {
                ContentUnavailableView(
                    "No Projects Detected",
                    systemImage: "folder",
                    description: Text("Projects will appear as you work in IDEs")
                )
            } else {
                List {
                    ForEach(projects, id: \.path) { project in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)

                            VStack(alignment: .leading) {
                                Text(project.name)
                                    .fontWeight(.medium)
                                Text(project.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text("\(project.activityCount) activities")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Projects")
    }

    private var projects: [(name: String, path: String, activityCount: Int)] {
        var projectCounts: [String: Int] = [:]
        for activity in activities {
            if let path = activity.projectPath, !path.isEmpty {
                projectCounts[path, default: 0] += 1
            }
        }

        return projectCounts.map { path, count in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return (name: name.isEmpty ? path : name, path: path, activityCount: count)
        }
        .sorted { $0.activityCount > $1.activityCount }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
