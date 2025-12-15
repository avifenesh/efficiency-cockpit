import Foundation
import SwiftData
import Combine

@MainActor
final class ActivityTrackingService: ObservableObject {
    @Published private(set) var isTracking: Bool = false
    @Published private(set) var currentActivity: Activity?

    // Core trackers
    private let windowTracker = WindowTracker()
    private let browserTracker = BrowserTabTracker()
    private let ideTracker = IDEFileTracker()
    private let gitTracker = GitActivityTracker()
    private let aiTracker = AIToolUsageTracker()

    private var pollingTask: Task<Void, Never>?
    private var modelContext: ModelContext?

    /// Polling interval in seconds (default 5 seconds)
    var pollingInterval: TimeInterval = 5.0

    /// Batch size before persisting to database
    private let batchSize = 10
    private var pendingActivities: [Activity] = []

    private var lastWindowInfo: WindowInfo?
    private var lastActivityTime: Date?
    private var lastBrowserURL: String?
    private var lastGitBranch: [String: String] = [:] // repoPath -> branch
    private var lastGitCommitHash: [String: String] = [:] // repoPath -> commit hash

    // MARK: - Lifecycle

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func startTracking() async {
        guard !isTracking else { return }
        isTracking = true

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureActivity()
                try? await Task.sleep(for: .seconds(self?.pollingInterval ?? 5.0))
            }
        }
    }

    func stopTracking() {
        pollingTask?.cancel()
        pollingTask = nil
        isTracking = false

        // Flush any pending activities
        flushPendingActivities()
    }

    // MARK: - Activity Capture

    private func captureActivity() async {
        guard let windowInfo = windowTracker.getActiveWindow() else {
            return
        }

        // Check if activity changed
        guard hasActivityChanged(windowInfo) else {
            return
        }

        // Calculate duration for previous activity
        updatePreviousActivityDuration()

        // Create new activity with enhanced tracking
        let activity = await createEnhancedActivity(from: windowInfo)
        currentActivity = activity
        lastWindowInfo = windowInfo
        lastActivityTime = Date()

        // Queue for persistence
        pendingActivities.append(activity)

        // Flush if batch size reached
        if pendingActivities.count >= batchSize {
            flushPendingActivities()
        }
    }

    private func hasActivityChanged(_ current: WindowInfo) -> Bool {
        guard let last = lastWindowInfo else {
            return true
        }

        // App changed = new activity
        if last.bundleId != current.bundleId {
            return true
        }

        // Window title changed = new activity (file switch, tab switch, etc.)
        if last.windowTitle != current.windowTitle {
            return true
        }

        return false
    }

    /// Determine if this is a window focus change (same app, different window)
    private func isWindowFocusChange(_ current: WindowInfo) -> Bool {
        guard let last = lastWindowInfo else { return false }
        return last.bundleId == current.bundleId && last.windowTitle != current.windowTitle
    }

    private func updatePreviousActivityDuration() {
        guard let lastTime = lastActivityTime,
              let lastActivity = pendingActivities.last ?? currentActivity else {
            return
        }

        lastActivity.duration = Date().timeIntervalSince(lastTime)
    }

    // MARK: - Enhanced Activity Creation

    private func createEnhancedActivity(from windowInfo: WindowInfo) async -> Activity {
        let activityType = determineActivityType(from: windowInfo)
        var url: String?
        var filePath: String?
        var projectPath: String?

        // Enhanced tracking based on app type
        if let bundleId = windowInfo.bundleId {
            // Browser tracking
            if BrowserTabTracker.supportedBrowsers.keys.contains(bundleId) {
                if let tab = browserTracker.getActiveTab(for: bundleId) {
                    url = tab.url
                    lastBrowserURL = url
                }
            }

            // IDE tracking
            if IDEFileTracker.supportedIDEs.keys.contains(bundleId) {
                if let context = ideTracker.getIDEContext(bundleId: bundleId, windowTitle: windowInfo.windowTitle) {
                    filePath = context.fileName
                    projectPath = context.projectName

                    // Check for git repo and activity
                    if let project = context.projectPath ?? context.projectName {
                        let expandedPath = (project as NSString).expandingTildeInPath
                        if let gitActivity = checkGitActivity(at: expandedPath) {
                            // If git activity detected, create a separate git activity
                            let gitAct = Activity(
                                type: gitActivity.type,
                                appBundleId: bundleId,
                                appName: windowInfo.ownerName,
                                windowTitle: gitActivity.message,
                                filePath: nil,
                                projectPath: gitActivity.repoPath
                            )
                            pendingActivities.append(gitAct)
                            projectPath = "\(gitActivity.repoPath) (\(gitActivity.branch))"
                        } else if gitTracker.isGitRepository(expandedPath) {
                            if let status = gitTracker.getGitStatus(at: expandedPath) {
                                projectPath = "\(status.repoPath) (\(status.branch ?? "detached"))"
                            }
                        }
                    }
                }
            }

            // Fallback to window title parsing
            if filePath == nil {
                filePath = windowTracker.extractFilePathFromTitle(windowInfo.windowTitle, bundleId: bundleId)
            }
            if projectPath == nil {
                projectPath = windowTracker.extractProjectFromTitle(windowInfo.windowTitle, bundleId: bundleId)
            }
        }

        return Activity(
            type: activityType,
            appBundleId: windowInfo.bundleId,
            appName: windowInfo.ownerName,
            windowTitle: windowInfo.windowTitle,
            url: url,
            filePath: filePath,
            projectPath: projectPath
        )
    }

    // MARK: - Git Activity Detection

    private struct GitActivityInfo {
        let type: ActivityType
        let repoPath: String
        let branch: String
        let message: String
    }

    private func checkGitActivity(at path: String) -> GitActivityInfo? {
        guard let repoPath = gitTracker.findGitDirectory(from: path) else {
            return nil
        }

        // Check for branch change
        if let currentBranch = gitTracker.getCurrentBranch(at: repoPath) {
            if let lastBranch = lastGitBranch[repoPath], lastBranch != currentBranch {
                lastGitBranch[repoPath] = currentBranch
                return GitActivityInfo(
                    type: .gitBranch,
                    repoPath: repoPath,
                    branch: currentBranch,
                    message: "Switched to branch: \(currentBranch)"
                )
            }
            lastGitBranch[repoPath] = currentBranch

            // Check for new commit
            if let lastCommit = gitTracker.getLastCommit(at: repoPath) {
                if let lastHash = lastGitCommitHash[repoPath], lastHash != lastCommit.hash {
                    lastGitCommitHash[repoPath] = lastCommit.hash
                    return GitActivityInfo(
                        type: .gitCommit,
                        repoPath: repoPath,
                        branch: currentBranch,
                        message: "Commit: \(lastCommit.message)"
                    )
                }
                lastGitCommitHash[repoPath] = lastCommit.hash
            }
        }

        return nil
    }

    private func determineActivityType(from windowInfo: WindowInfo) -> ActivityType {
        guard let bundleId = windowInfo.bundleId else {
            return .appSwitch
        }

        // Check if this is a window focus change within same app
        let isWindowChange = isWindowFocusChange(windowInfo)

        // AI tool detection (highest priority)
        if aiTracker.detectAITool(bundleId: bundleId) != nil {
            return .aiToolUse
        }

        // Check for AI in browser
        if BrowserTabTracker.supportedBrowsers.keys.contains(bundleId) {
            if let url = lastBrowserURL, aiTracker.detectAIToolFromURL(url) != nil {
                return .aiToolUse
            }
            return .browserNavigation
        }

        // Terminal detection - expanded list
        let terminals = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "co.zeit.hyper",
            "com.github.wez.wezterm",
            "io.alacritty"
        ]
        if terminals.contains(bundleId) {
            if aiTracker.detectCLITool(from: windowInfo.windowTitle) != nil {
                return .aiToolUse
            }
            return .terminalCommand
        }

        // IDE detection - file open/edit
        if IDEFileTracker.supportedIDEs.keys.contains(bundleId) {
            // If switching files within same IDE, it's a window focus
            if isWindowChange {
                return .windowFocus
            }
            return .fileOpen
        }

        // Generic window focus within any app
        if isWindowChange {
            return .windowFocus
        }

        return .appSwitch
    }

    // MARK: - Persistence

    private func flushPendingActivities() {
        guard let context = modelContext, !pendingActivities.isEmpty else {
            return
        }

        for activity in pendingActivities {
            context.insert(activity)
        }

        do {
            try context.save()
            pendingActivities.removeAll()
        } catch {
            print("Failed to save activities: \(error)")
        }
    }

    // MARK: - Queries

    func getRecentActivities(limit: Int = 50) -> [Activity] {
        guard let context = modelContext else { return [] }

        let descriptor = FetchDescriptor<Activity>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        var limited = descriptor
        limited.fetchLimit = limit

        return (try? context.fetch(limited)) ?? []
    }

    func getTodayActivities() -> [Activity] {
        guard let context = modelContext else { return [] }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = #Predicate<Activity> { $0.timestamp >= startOfDay }

        let descriptor = FetchDescriptor<Activity>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Statistics

    func getActivityStats() -> ActivityStats {
        let todayActivities = getTodayActivities()

        let totalTime = todayActivities.compactMap { $0.duration }.reduce(0, +)
        let aiTime = todayActivities.filter { $0.type == .aiToolUse }.compactMap { $0.duration }.reduce(0, +)
        let codeTime = todayActivities.filter { $0.type == .fileOpen }.compactMap { $0.duration }.reduce(0, +)
        let browserTime = todayActivities.filter { $0.type == .browserNavigation }.compactMap { $0.duration }.reduce(0, +)

        let uniqueProjects = Set(todayActivities.compactMap { $0.projectPath })
        let contextSwitches = countContextSwitches(todayActivities)

        return ActivityStats(
            totalActiveTime: totalTime,
            aiToolTime: aiTime,
            codingTime: codeTime,
            browserTime: browserTime,
            projectCount: uniqueProjects.count,
            contextSwitchCount: contextSwitches
        )
    }

    private func countContextSwitches(_ activities: [Activity]) -> Int {
        guard activities.count > 1 else { return 0 }

        var switches = 0
        var lastProject: String?

        for activity in activities.reversed() {
            if let project = activity.projectPath {
                if let last = lastProject, last != project {
                    switches += 1
                }
                lastProject = project
            }
        }

        return switches
    }
}

// MARK: - Activity Stats

struct ActivityStats {
    let totalActiveTime: TimeInterval
    let aiToolTime: TimeInterval
    let codingTime: TimeInterval
    let browserTime: TimeInterval
    let projectCount: Int
    let contextSwitchCount: Int

    var aiToolPercentage: Double {
        guard totalActiveTime > 0 else { return 0 }
        return (aiToolTime / totalActiveTime) * 100
    }

    var codingPercentage: Double {
        guard totalActiveTime > 0 else { return 0 }
        return (codingTime / totalActiveTime) * 100
    }
}
