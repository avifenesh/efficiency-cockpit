import Foundation
import SwiftData
import Combine

/// Service responsible for tracking user activity across applications.
///
/// ## Thread Safety
/// This class is marked `@MainActor`, ensuring all property access and method calls
/// are serialized on the main thread. Background operations use `Task.detached` and
/// synchronize back via `MainActor.run` when updating shared state. This guarantees:
/// - No data races on `pendingActivities`, `lastGitBranch`, `lastGitCommitHash`, etc.
/// - SwiftData context operations happen on the correct actor
/// - Published properties update safely for SwiftUI observation
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

    // MARK: - Settings (read from UserDefaults)

    /// Polling interval in seconds
    var pollingInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "pollingInterval")
        return stored > 0 ? stored : 5.0
    }

    private var trackBrowserTabs: Bool {
        UserDefaults.standard.object(forKey: "trackBrowserTabs") as? Bool ?? true
    }

    private var trackIDEFiles: Bool {
        UserDefaults.standard.object(forKey: "trackIDEFiles") as? Bool ?? true
    }

    private var trackTerminalCommands: Bool {
        UserDefaults.standard.object(forKey: "trackTerminalCommands") as? Bool ?? true
    }

    private var trackGitActivity: Bool {
        UserDefaults.standard.object(forKey: "trackGitActivity") as? Bool ?? true
    }

    private var trackAITools: Bool {
        UserDefaults.standard.object(forKey: "trackAITools") as? Bool ?? true
    }

    // MARK: - Constants

    private enum Constants {
        /// Number of activities to batch before persisting to database
        static let batchSize = 5
        /// Maximum pending activities to prevent unbounded memory growth on flush failures
        static let maxPendingActivities = 100
        /// Maximum seconds between automatic flushes
        static let maxTimeBetweenFlushes: TimeInterval = 30.0
        /// Git polling interval in seconds
        static let gitPollingInterval: TimeInterval = 30.0
        /// Maximum directory items to scan when discovering projects
        static let maxDirectoryItemsToScan = 100
    }

    private var pendingActivities: [Activity] = []
    private var lastFlushTime: Date = Date()

    private var lastWindowInfo: WindowInfo?
    private var lastActivityTime: Date?
    private var lastBrowserURL: String?
    private var lastGitBranch: [String: String] = [:] // repoPath -> branch
    private var lastGitCommitHash: [String: String] = [:] // repoPath -> commit hash

    // Context switch tracking
    private var lastProjectPath: String?
    private var projectStartTime: Date?

    // Known project directories to monitor for git
    private var knownProjectPaths: Set<String> = []
    private var gitPollingTask: Task<Void, Never>?
    private var inactivityTask: Task<Void, Never>?
    private var isConfigured = false

    // Inactivity tracking for auto-snapshot suggestions
    private var lastActiveTime: Date = Date()
    private var inactivityNotificationSent = false
    private var inactivityThresholdMinutes: Int {
        UserDefaults.standard.object(forKey: "inactivityThresholdMinutes") as? Int ?? 15
    }
    private var autoSnapshotSuggestionEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoSnapshotSuggestionEnabled") as? Bool ?? true
    }

    // MARK: - Lifecycle

    /// Configure the tracking service with a model context.
    /// This method should only be called once - subsequent calls are ignored to prevent reconfiguration.
    func configure(modelContext: ModelContext) {
        guard !isConfigured else {
            print("[Activity] Already configured, ignoring duplicate configure call")
            return
        }
        self.modelContext = modelContext
        isConfigured = true
        // Discover project directories in background (don't block configure)
        Task.detached(priority: .background) { [weak self] in
            await self?.discoverProjectDirectories()
        }
    }

    func startTracking() async {
        guard !isTracking else { return }
        isTracking = true

        // Main activity polling
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureActivity()
                try? await Task.sleep(for: .seconds(self?.pollingInterval ?? 5.0))
            }
        }

        // Separate git polling to reduce resource usage
        gitPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollGitRepositories()
                try? await Task.sleep(for: .seconds(Constants.gitPollingInterval))
            }
        }

        // Inactivity detection for auto-snapshot suggestions
        inactivityTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkInactivity()
                try? await Task.sleep(for: .seconds(60)) // Check every minute
            }
        }
    }

    /// Check for user inactivity and suggest snapshot capture
    private func checkInactivity() async {
        guard autoSnapshotSuggestionEnabled,
              let lastProject = lastProjectPath,
              !inactivityNotificationSent else {
            return
        }

        let inactiveSeconds = Date().timeIntervalSince(lastActiveTime)
        let thresholdSeconds = TimeInterval(inactivityThresholdMinutes * 60)

        if inactiveSeconds >= thresholdSeconds {
            let projectName = URL(fileURLWithPath: lastProject).lastPathComponent
            NotificationService.shared.sendInactivitySnapshotSuggestion(projectName: projectName)
            inactivityNotificationSent = true
        }
    }

    /// Discover common project directories (runs in background, file operations off main thread)
    nonisolated private func discoverProjectDirectories() async {
        let home = NSHomeDirectory()
        let commonPaths = [
            home,
            "\(home)/Projects",
            "\(home)/Developer",
            "\(home)/workspace",
            "\(home)/code",
            "\(home)/src",
            "\(home)/repos",
            "\(home)/github"
        ]

        let fileManager = FileManager.default
        let gitTracker = GitActivityTracker() // Create local instance to avoid actor isolation
        var discoveredPaths: Set<String> = []

        for basePath in commonPaths {
            guard fileManager.fileExists(atPath: basePath) else { continue }

            // Check if basePath itself is a git repo
            if gitTracker.isGitRepository(basePath) {
                discoveredPaths.insert(basePath)
            }

            // Check immediate subdirectories (limit depth to avoid slow scans)
            if let contents = try? fileManager.contentsOfDirectory(atPath: basePath) {
                for item in contents.prefix(Constants.maxDirectoryItemsToScan) {
                    let fullPath = "\(basePath)/\(item)"
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        if gitTracker.isGitRepository(fullPath) {
                            discoveredPaths.insert(fullPath)
                        }
                    }
                }
            }
        }

        // Update on main actor
        await MainActor.run { [discoveredPaths] in
            self.knownProjectPaths = discoveredPaths
            print("[Git] Discovered \(discoveredPaths.count) git repositories")
        }
    }

    /// Poll known git repositories for changes
    private func pollGitRepositories() async {
        guard trackGitActivity else { return }
        for repoPath in knownProjectPaths {
            if let gitActivity = checkGitActivity(at: repoPath) {
                let activity = Activity(
                    type: gitActivity.type,
                    appBundleId: nil,
                    appName: "Git",
                    windowTitle: gitActivity.message,
                    filePath: nil,
                    projectPath: gitActivity.repoPath
                )
                pendingActivities.append(activity)
                flushPendingActivities()
            }
        }
    }

    func stopTracking() {
        pollingTask?.cancel()
        pollingTask = nil
        gitPollingTask?.cancel()
        gitPollingTask = nil
        inactivityTask?.cancel()
        inactivityTask = nil
        isTracking = false

        // Flush any pending activities
        flushPendingActivities()
    }

    deinit {
        pollingTask?.cancel()
        gitPollingTask?.cancel()
        inactivityTask?.cancel()
    }

    // MARK: - Activity Capture

    private func captureActivity() async {
        guard let windowInfo = windowTracker.getActiveWindow() else {
            return
        }

        // Reset inactivity tracking on any window detection
        lastActiveTime = Date()
        inactivityNotificationSent = false

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

        // Check for context switch (project change)
        checkForContextSwitch(newProjectPath: activity.projectPath)

        // Queue for persistence
        pendingActivities.append(activity)

        // Flush when batch is ready or time threshold passed
        // With 5-second polling and batchSize=5, flushes every ~25 seconds during active use
        // Time threshold ensures flush even during low activity periods
        let timeSinceFlush = Date().timeIntervalSince(lastFlushTime)
        if pendingActivities.count >= Constants.batchSize || timeSinceFlush > Constants.maxTimeBetweenFlushes {
            flushPendingActivities()
            lastFlushTime = Date()
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
        guard let lastTime = lastActivityTime else { return }

        // Capture the last activity once to avoid race conditions
        // (pendingActivities could be modified by flushPendingActivities between checks)
        let lastPendingActivity = pendingActivities.last
        let activityToUpdate = lastPendingActivity ?? currentActivity
        guard let activity = activityToUpdate else { return }

        activity.duration = Date().timeIntervalSince(lastTime)

        // Only try to save if the activity wasn't in pending list
        // (meaning it was already persisted)
        if lastPendingActivity == nil, let context = modelContext {
            do {
                try context.save()
            } catch {
                print("[Activity] Failed to update activity duration: \(error)")
            }
        }
    }

    // MARK: - Context Switch Detection

    private func checkForContextSwitch(newProjectPath: String?) {
        // Skip if no project path (not working in a project)
        guard let newPath = newProjectPath, !newPath.isEmpty else {
            // If moving away from a project, reset tracking
            if lastProjectPath != nil {
                lastProjectPath = nil
                projectStartTime = nil
            }
            return
        }

        // If same project, no switch
        if lastProjectPath == newPath {
            return
        }

        // Check if we should send a nudge for leaving the previous project
        if let previousProject = lastProjectPath, let startTime = projectStartTime {
            let settings = NotificationService.shared.settings
            let thresholdSeconds = TimeInterval(settings.contextSwitchThresholdMinutes * 60)
            let timeInProject = Date().timeIntervalSince(startTime)

            // Only nudge if spent significant time in previous project
            if timeInProject >= thresholdSeconds {
                let previousName = URL(fileURLWithPath: previousProject).lastPathComponent
                let newName = URL(fileURLWithPath: newPath).lastPathComponent
                NotificationService.shared.sendContextSwitchNudge(fromProject: previousName, toProject: newName)
            }
        }

        // Update tracking for new project
        lastProjectPath = newPath
        projectStartTime = Date()
    }

    // MARK: - Enhanced Activity Creation

    /// Context collected during activity tracking
    private struct ActivityContext {
        var url: String?
        var filePath: String?
        var projectPath: String?
    }

    private func createEnhancedActivity(from windowInfo: WindowInfo) async -> Activity {
        var context = ActivityContext()

        if let bundleId = windowInfo.bundleId {
            // Track browser URL first (needed for activity type determination)
            trackBrowserActivity(bundleId: bundleId, context: &context)
            trackIDEActivity(bundleId: bundleId, windowInfo: windowInfo, context: &context)
            trackTerminalActivity(bundleId: bundleId, windowInfo: windowInfo, context: &context)

            // Fallback to window title parsing for non-IDEs
            if context.filePath == nil && !IDEFileTracker.supportedIDEs.keys.contains(bundleId) {
                context.filePath = windowTracker.extractFilePathFromTitle(windowInfo.windowTitle, bundleId: bundleId)
            }
            if context.projectPath == nil && !IDEFileTracker.supportedIDEs.keys.contains(bundleId) {
                context.projectPath = windowTracker.extractProjectFromTitle(windowInfo.windowTitle, bundleId: bundleId)
            }
        }

        // Determine activity type after browser URL is fetched (lastBrowserURL is now current)
        let activityType = determineActivityType(from: windowInfo)

        return Activity(
            type: activityType,
            appBundleId: windowInfo.bundleId,
            appName: windowInfo.ownerName,
            windowTitle: windowInfo.windowTitle,
            url: context.url,
            filePath: context.filePath,
            projectPath: context.projectPath
        )
    }

    // MARK: - Activity Tracking Helpers

    private func trackBrowserActivity(bundleId: String, context: inout ActivityContext) {
        // Clear stale URL when not on a browser
        guard BrowserTabTracker.supportedBrowsers.keys.contains(bundleId) else {
            lastBrowserURL = nil
            return
        }

        guard trackBrowserTabs else { return }

        if let tab = browserTracker.getActiveTab(for: bundleId) {
            context.url = tab.url
            lastBrowserURL = tab.url
        }
    }

    private func trackIDEActivity(bundleId: String, windowInfo: WindowInfo, context: inout ActivityContext) {
        guard trackIDEFiles,
              IDEFileTracker.supportedIDEs.keys.contains(bundleId) else { return }

        // Get context from IDE tracker
        if let ideContext = ideTracker.getIDEContext(bundleId: bundleId, windowTitle: windowInfo.windowTitle) {
            context.filePath = ideContext.fileName
            context.projectPath = ideContext.projectName
        }

        // Fallback to window title extraction
        if context.filePath == nil {
            context.filePath = windowTracker.extractFilePathFromTitle(windowInfo.windowTitle, bundleId: bundleId)
        }
        if context.projectPath == nil {
            context.projectPath = windowTracker.extractProjectFromTitle(windowInfo.windowTitle, bundleId: bundleId)
        }

        // Try to find git repo and enrich project path
        if let projectName = context.projectPath {
            context.projectPath = enrichProjectWithGitInfo(
                projectName: projectName,
                bundleId: bundleId,
                ownerName: windowInfo.ownerName
            )
        }
    }

    private func trackTerminalActivity(bundleId: String, windowInfo: WindowInfo, context: inout ActivityContext) {
        guard trackTerminalCommands,
              AppIdentifiers.Terminals.all.contains(bundleId),
              let title = windowInfo.windowTitle else { return }

        // Extract path from terminal title
        guard let path = extractPathFromTerminalTitle(title) else { return }

        // Check for git and set project path
        if let gitActivity = checkGitActivity(at: path) {
            let gitAct = Activity(
                type: gitActivity.type,
                appBundleId: bundleId,
                appName: windowInfo.ownerName,
                windowTitle: gitActivity.message,
                filePath: nil,
                projectPath: gitActivity.repoPath
            )
            pendingActivities.append(gitAct)
            context.projectPath = "\(URL(fileURLWithPath: path).lastPathComponent) (\(gitActivity.branch))"
        } else if gitTracker.isGitRepository(path) {
            if let status = gitTracker.getGitStatus(at: path) {
                context.projectPath = "\(URL(fileURLWithPath: path).lastPathComponent) (\(status.branch ?? "detached"))"
            }
        } else {
            context.projectPath = URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func extractPathFromTerminalTitle(_ title: String) -> String? {
        // Common formats: "user@host:~/path" or "~/path" or "/Users/user/path"
        if title.contains("~") {
            if let tildeIndex = title.range(of: "~") {
                var pathPart = String(title[tildeIndex.lowerBound...])
                // Remove trailing parts like " — zsh"
                if let dashIndex = pathPart.range(of: " —") ?? pathPart.range(of: " -") {
                    pathPart = String(pathPart[..<dashIndex.lowerBound])
                }
                return (pathPart as NSString).expandingTildeInPath
            }
        } else if title.contains("/Users/") || title.contains("/home/") {
            let parts = title.components(separatedBy: " ")
            for part in parts {
                if part.hasPrefix("/Users/") || part.hasPrefix("/home/") {
                    return part
                }
            }
        }
        return nil
    }

    private func enrichProjectWithGitInfo(projectName: String, bundleId: String, ownerName: String) -> String {
        let home = NSHomeDirectory()
        let possiblePaths = [
            "\(home)/\(projectName)",
            "\(home)/Projects/\(projectName)",
            "\(home)/Developer/\(projectName)",
            "\(home)/workspace/\(projectName)",
            "\(home)/code/\(projectName)",
            "\(home)/src/\(projectName)"
        ]

        for path in possiblePaths {
            if let gitActivity = checkGitActivity(at: path) {
                let gitAct = Activity(
                    type: gitActivity.type,
                    appBundleId: bundleId,
                    appName: ownerName,
                    windowTitle: gitActivity.message,
                    filePath: nil,
                    projectPath: gitActivity.repoPath
                )
                pendingActivities.append(gitAct)
                return "\(projectName) (\(gitActivity.branch))"
            } else if gitTracker.isGitRepository(path) {
                if let status = gitTracker.getGitStatus(at: path) {
                    return "\(projectName) (\(status.branch ?? "detached"))"
                }
            }
        }

        return projectName
    }

    // MARK: - Git Activity Detection

    private struct GitActivityInfo {
        let type: ActivityType
        let repoPath: String
        let branch: String
        let message: String
    }

    /// Checks for git activity (branch switch or commit) at the given path.
    /// Uses lastGitBranch/lastGitCommitHash to deduplicate - only returns an activity
    /// when there's an actual change, preventing duplicate activities when multiple
    /// callers (pollGitRepositories, trackTerminalActivity, enrichProjectWithGitInfo)
    /// check the same repo in the same or subsequent cycles.
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

        // Dedicated AI tool apps (Claude desktop, ChatGPT app, etc.)
        if trackAITools, aiTracker.detectAITool(bundleId: bundleId) != nil {
            return .aiToolUse
        }

        // Check for AI in browser
        if BrowserTabTracker.supportedBrowsers.keys.contains(bundleId) {
            if trackAITools, let url = lastBrowserURL, aiTracker.detectAIToolFromURL(url) != nil {
                return .aiToolUse
            }
            return .browserNavigation
        }

        // Terminal detection
        if AppIdentifiers.Terminals.all.contains(bundleId) {
            // Check if running AI CLI tool (claude, aider, etc.)
            if trackAITools, aiTracker.detectCLITool(from: windowInfo.windowTitle) != nil {
                return .aiToolUse
            }
            return .terminalCommand
        }

        // IDE detection - check for AI usage in IDE first
        if IDEFileTracker.supportedIDEs.keys.contains(bundleId) {
            // Check if using AI features in IDE (Cursor AI, Copilot chat, etc.)
            if trackAITools, let title = windowInfo.windowTitle?.lowercased() {
                if title.contains("composer") || title.contains("chat") ||
                   title.contains("copilot") || title.contains("ai") {
                    return .aiToolUse
                }
            }

            // Regular IDE file activity
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
            print("[Activity] Failed to save activities: \(error)")
            // Prevent unbounded memory growth on repeated flush failures
            if pendingActivities.count > Constants.maxPendingActivities {
                let dropCount = pendingActivities.count - Constants.maxPendingActivities
                pendingActivities.removeFirst(dropCount)
                print("[Activity] Dropped \(dropCount) oldest activities due to memory limit")
            }
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
