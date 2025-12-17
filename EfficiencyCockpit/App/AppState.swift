import SwiftUI
import SwiftData
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var isTracking: Bool = false
    @Published var currentActivity: Activity?
    @Published var todayStats: DailyStats = DailyStats()

    let permissionManager = PermissionManager()
    let activityTracker: ActivityTrackingService
    let claudeService: ClaudeService
    let contentIndexingService: ContentIndexingService

    private var cancellables = Set<AnyCancellable>()
    private var modelContext: ModelContext?
    private var statsTimer: Timer?
    private var isRefreshingStats: Bool = false

    /// Interval for refreshing statistics (in seconds)
    private static let statsRefreshInterval: TimeInterval = 30.0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.activityTracker = ActivityTrackingService()
        self.claudeService = ClaudeService()
        self.contentIndexingService = ContentIndexingService.shared

        // Configure services with model context
        activityTracker.configure(modelContext: modelContext)
        claudeService.configure(modelContext: modelContext)
        contentIndexingService.configure(modelContext: modelContext)

        // Bind tracker state
        activityTracker.$isTracking
            .assign(to: &$isTracking)

        activityTracker.$currentActivity
            .assign(to: &$currentActivity)

        // Auto-start tracking on launch
        Task {
            // Small delay to let UI initialize
            try? await Task.sleep(for: .seconds(1))
            await activityTracker.startTracking()
            // Initial stats calculation
            await refreshStats()
        }

        // Refresh stats periodically to reduce resource usage
        statsTimer = Timer.scheduledTimer(withTimeInterval: Self.statsRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshStats()
            }
        }
    }

    deinit {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    func refreshStats() async {
        // Prevent concurrent refreshes
        guard !isRefreshingStats else { return }
        isRefreshingStats = true
        defer { isRefreshingStats = false }

        guard let modelContext = modelContext else {
            print("[Stats] No model context")
            return
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())

        let predicate = #Predicate<Activity> { activity in
            activity.timestamp >= startOfDay
        }

        let descriptor = FetchDescriptor<Activity>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp)])

        do {
            let activities = try modelContext.fetch(descriptor)
            print("[Stats] Found \(activities.count) activities for today")

            var totalTime: TimeInterval = 0
            var appUsage: [String: TimeInterval] = [:]
            var switches = 0
            var focusSessions = 0
            var lastApp: String?
            var focusStartTime: Date?

            let focusThreshold: TimeInterval = 5 * 60 // 5 minutes in seconds

            for activity in activities {
                // Count app switches
                if let appName = activity.appName, appName != lastApp {
                    switches += 1

                    // Check if previous focus session qualifies (> 5 minutes in same app)
                    if let startTime = focusStartTime {
                        let sessionDuration = activity.timestamp.timeIntervalSince(startTime)
                        if sessionDuration >= focusThreshold {
                            focusSessions += 1
                        }
                    }

                    // Start tracking new focus session
                    focusStartTime = activity.timestamp
                    lastApp = appName
                }

                // Accumulate time
                if let duration = activity.duration, duration > 0 {
                    totalTime += duration
                    if let appName = activity.appName {
                        appUsage[appName, default: 0] += duration
                    }
                }
            }

            // Check if the final session qualifies (still in the same app)
            if let startTime = focusStartTime,
               let lastActivity = activities.last {
                let finalDuration = lastActivity.timestamp.timeIntervalSince(startTime) + (lastActivity.duration ?? 0)
                if finalDuration >= focusThreshold {
                    focusSessions += 1
                }
            }

            // Update stats
            let newStats = DailyStats(
                totalActiveTime: totalTime,
                appUsage: appUsage,
                focusSessionCount: focusSessions,
                contextSwitchCount: max(switches - 1, 0) // First activity isn't a switch
            )
            print("[Stats] Total time: \(Int(totalTime))s, Switches: \(newStats.contextSwitchCount), Focus: \(newStats.focusSessionCount)")
            todayStats = newStats
        } catch {
            print("[Stats] Failed to fetch activities: \(error)")
        }
    }

    func startTracking() {
        Task {
            await activityTracker.startTracking()
        }
    }

    func stopTracking() {
        activityTracker.stopTracking()
    }

    func toggleTracking() {
        if isTracking {
            stopTracking()
        } else {
            startTracking()
        }
    }

    /// Clear all activity data from the database
    func clearAllData() async throws {
        guard let modelContext = modelContext else { return }

        // Stop tracking temporarily
        let wasTracking = isTracking
        if wasTracking {
            activityTracker.stopTracking()
        }

        // Delete all activities
        try modelContext.delete(model: Activity.self)

        // Delete all insights
        try modelContext.delete(model: ProductivityInsight.self)

        // Delete all sessions
        try modelContext.delete(model: AppSession.self)

        // Delete all summaries
        try modelContext.delete(model: DailySummary.self)

        try modelContext.save()

        // Reset stats
        todayStats = DailyStats()

        // Restart tracking if it was running
        if wasTracking {
            startTracking()
        }
    }
}

struct DailyStats {
    var totalActiveTime: TimeInterval
    var appUsage: [String: TimeInterval]
    var focusSessionCount: Int
    var contextSwitchCount: Int

    init(totalActiveTime: TimeInterval = 0, appUsage: [String: TimeInterval] = [:], focusSessionCount: Int = 0, contextSwitchCount: Int = 0) {
        self.totalActiveTime = totalActiveTime
        self.appUsage = appUsage
        self.focusSessionCount = focusSessionCount
        self.contextSwitchCount = contextSwitchCount
    }
}

// Preview helper
extension AppState {
    @MainActor
    static var preview: AppState {
        let schema = Schema([
            Activity.self,
            AppSession.self,
            ProductivityInsight.self,
            DailySummary.self,
            ContextSnapshot.self,
            Decision.self,
            AIInteraction.self,
            ContentIndex.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return AppState(modelContext: ModelContext(container))
    }
}
