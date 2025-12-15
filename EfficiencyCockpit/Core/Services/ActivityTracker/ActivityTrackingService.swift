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
    private let batchSize = 5
    private var pendingActivities: [Activity] = []
    private var lastFlushTime: Date = Date()

    private var lastWindowInfo: WindowInfo?
    private var lastActivityTime: Date?
    private var lastBrowserURL: String?
    private var lastGitBranch: [String: String] = [:] // repoPath -> branch
    private var lastGitCommitHash: [String: String] = [:] // repoPath -> commit hash

    // Known project directories to monitor for git
    private var knownProjectPaths: Set<String> = []
    private var gitPollingTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        // Discover project directories
        discoverProjectDirectories()
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

        // Separate git polling (every 10 seconds)
        gitPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollGitRepositories()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Discover common project directories
    private func discoverProjectDirectories() {
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

        for basePath in commonPaths {
            guard fileManager.fileExists(atPath: basePath) else { continue }

            // Check if basePath itself is a git repo
            if gitTracker.isGitRepository(basePath) {
                knownProjectPaths.insert(basePath)
            }

            // Check immediate subdirectories
            if let contents = try? fileManager.contentsOfDirectory(atPath: basePath) {
                for item in contents.prefix(50) { // Limit to 50 to avoid too many
                    let fullPath = "\(basePath)/\(item)"
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        if gitTracker.isGitRepository(fullPath) {
                            knownProjectPaths.insert(fullPath)
                        }
                    }
                }
            }
        }

        print("[Git] Discovered \(knownProjectPaths.count) git repositories")
    }

    /// Poll known git repositories for changes
    private func pollGitRepositories() async {
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

        // Flush immediately for first few activities, then batch
        // Also flush every 30 seconds to ensure data is saved
        let timeSinceFlush = Date().timeIntervalSince(lastFlushTime)
        if pendingActivities.count <= 3 || pendingActivities.count >= batchSize || timeSinceFlush > 30 {
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
                }

                // Also try to extract from window title directly
                if filePath == nil {
                    filePath = windowTracker.extractFilePathFromTitle(windowInfo.windowTitle, bundleId: bundleId)
                }
                if projectPath == nil {
                    projectPath = windowTracker.extractProjectFromTitle(windowInfo.windowTitle, bundleId: bundleId)
                }

                // Try to find git repo in common project locations
                if let projectName = projectPath {
                    let possiblePaths = [
                        NSHomeDirectory() + "/" + projectName,
                        NSHomeDirectory() + "/Projects/" + projectName,
                        NSHomeDirectory() + "/Developer/" + projectName,
                        NSHomeDirectory() + "/workspace/" + projectName,
                        NSHomeDirectory() + "/code/" + projectName,
                        NSHomeDirectory() + "/src/" + projectName
                    ]

                    for path in possiblePaths {
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
                            projectPath = "\(projectName) (\(gitActivity.branch))"
                            break
                        } else if gitTracker.isGitRepository(path) {
                            if let status = gitTracker.getGitStatus(at: path) {
                                projectPath = "\(projectName) (\(status.branch ?? "detached"))"
                                break
                            }
                        }
                    }
                }
            }

            // Terminal project detection from window title
            let terminals = [
                "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                "net.kovidgoyal.kitty", "co.zeit.hyper", "com.github.wez.wezterm", "io.alacritty"
            ]
            if terminals.contains(bundleId), let title = windowInfo.windowTitle {
                // Try to extract path from terminal title (often shows current directory)
                // Common formats: "user@host:~/path" or "~/path" or "/Users/user/path"
                var extractedPath: String?

                if title.contains("~") {
                    if let tildeIndex = title.range(of: "~") {
                        var pathPart = String(title[tildeIndex.lowerBound...])
                        // Remove trailing parts like " — zsh"
                        if let dashIndex = pathPart.range(of: " —") ?? pathPart.range(of: " -") {
                            pathPart = String(pathPart[..<dashIndex.lowerBound])
                        }
                        extractedPath = (pathPart as NSString).expandingTildeInPath
                    }
                } else if title.contains("/Users/") || title.contains("/home/") {
                    // Try to find a path in the title
                    let parts = title.components(separatedBy: " ")
                    for part in parts {
                        if part.hasPrefix("/Users/") || part.hasPrefix("/home/") {
                            extractedPath = part
                            break
                        }
                    }
                }

                if let path = extractedPath {
                    // Check for git in this path
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
                        projectPath = "\(URL(fileURLWithPath: path).lastPathComponent) (\(gitActivity.branch))"
                    } else if gitTracker.isGitRepository(path) {
                        if let status = gitTracker.getGitStatus(at: path) {
                            projectPath = "\(URL(fileURLWithPath: path).lastPathComponent) (\(status.branch ?? "detached"))"
                        }
                    } else {
                        projectPath = URL(fileURLWithPath: path).lastPathComponent
                    }
                }
            }

            // Fallback to window title parsing for non-IDEs
            if filePath == nil && !IDEFileTracker.supportedIDEs.keys.contains(bundleId) {
                filePath = windowTracker.extractFilePathFromTitle(windowInfo.windowTitle, bundleId: bundleId)
            }
            if projectPath == nil && !IDEFileTracker.supportedIDEs.keys.contains(bundleId) {
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

        // Dedicated AI tool apps (Claude desktop, ChatGPT app, etc.)
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
            // Check if running AI CLI tool (claude, aider, etc.)
            if aiTracker.detectCLITool(from: windowInfo.windowTitle) != nil {
                return .aiToolUse
            }
            return .terminalCommand
        }

        // IDE detection - check for AI usage in IDE first
        if IDEFileTracker.supportedIDEs.keys.contains(bundleId) {
            // Check if using AI features in IDE (Cursor AI, Copilot chat, etc.)
            if let title = windowInfo.windowTitle?.lowercased() {
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
