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

    private var cancellables = Set<AnyCancellable>()
    private var modelContext: ModelContext?
    private var statsTimer: Timer?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.activityTracker = ActivityTrackingService()

        // Configure tracker with model context immediately
        activityTracker.configure(modelContext: modelContext)

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

        // Refresh stats every 10 seconds
        statsTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshStats()
            }
        }
    }

    func refreshStats() async {
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

            for activity in activities {
                // Count app switches
                if let appName = activity.appName, appName != lastApp {
                    switches += 1
                    lastApp = appName

                    // Check if previous focus session ended (switched away)
                    if focusStartTime != nil {
                        focusSessions += 1
                        focusStartTime = nil
                    }
                }

                // Accumulate time
                if let duration = activity.duration, duration > 0 {
                    totalTime += duration
                    if let appName = activity.appName {
                        appUsage[appName, default: 0] += duration
                    }
                }

                // Track focus sessions (time in same app > 5 minutes)
                if focusStartTime == nil {
                    focusStartTime = activity.timestamp
                }
            }

            // Update stats
            let newStats = DailyStats(
                totalActiveTime: totalTime,
                appUsage: appUsage,
                focusSessionCount: max(focusSessions, activities.isEmpty ? 0 : 1),
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
        let schema = Schema([Activity.self, AppSession.self, ProductivityInsight.self, DailySummary.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return AppState(modelContext: ModelContext(container))
    }
}
