import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var isTracking: Bool = false
    @Published var currentActivity: Activity?
    @Published var todayStats: DailyStats = DailyStats()

    let permissionManager = PermissionManager()
    let activityTracker: ActivityTrackingService

    private var cancellables = Set<AnyCancellable>()

    init() {
        self.activityTracker = ActivityTrackingService()

        // Bind tracker state
        activityTracker.$isTracking
            .assign(to: &$isTracking)

        activityTracker.$currentActivity
            .assign(to: &$currentActivity)
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
    var totalActiveTime: TimeInterval = 0
    var appUsage: [String: TimeInterval] = [:]
    var focusSessionCount: Int = 0
    var contextSwitchCount: Int = 0
}
