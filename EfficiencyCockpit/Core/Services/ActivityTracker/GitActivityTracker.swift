import Foundation

/// Tracks git activity by monitoring .git directories
final class GitActivityTracker {

    struct GitStatus {
        let repoPath: String
        let branch: String?
        let commitCount: Int
        let hasUncommittedChanges: Bool
        let lastCommitMessage: String?
        let lastCommitTime: Date?
    }

    struct GitCommit {
        let hash: String
        let message: String
        let author: String
        let timestamp: Date
        let repoPath: String
    }

    private var knownRepos: [String: GitStatus] = [:]
    private var lastCheckedCommits: [String: String] = [:] // repoPath -> lastCommitHash

    // MARK: - Git Status

    /// Get git status for a repository path
    func getGitStatus(at path: String) -> GitStatus? {
        let gitPath = findGitDirectory(from: path)
        guard let repoPath = gitPath else { return nil }

        let branch = getCurrentBranch(at: repoPath)
        let commitCount = getCommitCount(at: repoPath)
        let hasChanges = hasUncommittedChanges(at: repoPath)
        let lastCommit = getLastCommit(at: repoPath)

        let status = GitStatus(
            repoPath: repoPath,
            branch: branch,
            commitCount: commitCount,
            hasUncommittedChanges: hasChanges,
            lastCommitMessage: lastCommit?.message,
            lastCommitTime: lastCommit?.timestamp
        )

        knownRepos[repoPath] = status
        return status
    }

    /// Find .git directory by walking up from path
    func findGitDirectory(from path: String) -> String? {
        var currentPath = path
        let fileManager = FileManager.default

        while currentPath != "/" {
            let gitPath = (currentPath as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
                return currentPath
            }

            currentPath = (currentPath as NSString).deletingLastPathComponent
        }

        return nil
    }

    // MARK: - Git Commands

    /// Get current branch name
    func getCurrentBranch(at repoPath: String) -> String? {
        let output = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], at: repoPath)
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get total commit count
    func getCommitCount(at repoPath: String) -> Int {
        guard let output = runGitCommand(["rev-list", "--count", "HEAD"], at: repoPath),
              let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return count
    }

    /// Check for uncommitted changes
    func hasUncommittedChanges(at repoPath: String) -> Bool {
        let output = runGitCommand(["status", "--porcelain"], at: repoPath)
        return !(output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Get the last commit
    func getLastCommit(at repoPath: String) -> GitCommit? {
        // Format: hash|message|author|timestamp
        let format = "%H|%s|%an|%at"
        guard let output = runGitCommand(["log", "-1", "--format=\(format)"], at: repoPath) else {
            return nil
        }

        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard parts.count >= 4 else { return nil }

        let timestamp = TimeInterval(parts[3]) ?? 0

        return GitCommit(
            hash: parts[0],
            message: parts[1],
            author: parts[2],
            timestamp: Date(timeIntervalSince1970: timestamp),
            repoPath: repoPath
        )
    }

    /// Get recent commits (for detecting new commits)
    func getRecentCommits(at repoPath: String, limit: Int = 10) -> [GitCommit] {
        let format = "%H|%s|%an|%at"
        guard let output = runGitCommand(["log", "-\(limit)", "--format=\(format)"], at: repoPath) else {
            return []
        }

        return output.components(separatedBy: .newlines).compactMap { line -> GitCommit? in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 4 else { return nil }

            let timestamp = TimeInterval(parts[3]) ?? 0

            return GitCommit(
                hash: parts[0],
                message: parts[1],
                author: parts[2],
                timestamp: Date(timeIntervalSince1970: timestamp),
                repoPath: repoPath
            )
        }
    }

    // MARK: - Change Detection

    /// Check if there's a new commit since last check
    func checkForNewCommits(at repoPath: String) -> GitCommit? {
        guard let lastCommit = getLastCommit(at: repoPath) else {
            return nil
        }

        let previousHash = lastCheckedCommits[repoPath]
        lastCheckedCommits[repoPath] = lastCommit.hash

        // If we have a previous hash and it's different, we have a new commit
        if let previous = previousHash, previous != lastCommit.hash {
            return lastCommit
        }

        return nil
    }

    /// Get changed files in working directory
    func getChangedFiles(at repoPath: String) -> [String] {
        guard let output = runGitCommand(["diff", "--name-only"], at: repoPath) else {
            return []
        }

        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Get staged files
    func getStagedFiles(at repoPath: String) -> [String] {
        guard let output = runGitCommand(["diff", "--cached", "--name-only"], at: repoPath) else {
            return []
        }

        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Repository Info

    /// Get repository name from path
    func getRepositoryName(from repoPath: String) -> String {
        return (repoPath as NSString).lastPathComponent
    }

    /// Get remote URL
    func getRemoteURL(at repoPath: String) -> String? {
        let output = runGitCommand(["remote", "get-url", "origin"], at: repoPath)
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if path is inside a git repository
    func isGitRepository(_ path: String) -> Bool {
        return findGitDirectory(from: path) != nil
    }

    // MARK: - Helpers

    private func runGitCommand(_ arguments: [String], at path: String) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            }
        } catch {
            // Git command failed - path might not be a repo
        }

        return nil
    }
}

// MARK: - Git Activity Categorization

extension GitActivityTracker {

    enum GitActivityType {
        case commit
        case branchSwitch
        case merge
        case rebase
        case push
        case pull
        case stash

        var displayName: String {
            switch self {
            case .commit: return "Commit"
            case .branchSwitch: return "Branch Switch"
            case .merge: return "Merge"
            case .rebase: return "Rebase"
            case .push: return "Push"
            case .pull: return "Pull"
            case .stash: return "Stash"
            }
        }
    }

    /// Analyze commit message to determine type
    func categorizeCommit(_ message: String) -> CommitCategory {
        let lowercased = message.lowercased()

        if lowercased.hasPrefix("merge") {
            return .merge
        }
        if lowercased.hasPrefix("fix") || lowercased.contains("bugfix") {
            return .bugfix
        }
        if lowercased.hasPrefix("feat") || lowercased.contains("feature") {
            return .feature
        }
        if lowercased.hasPrefix("refactor") {
            return .refactor
        }
        if lowercased.hasPrefix("docs") || lowercased.contains("documentation") {
            return .documentation
        }
        if lowercased.hasPrefix("test") {
            return .test
        }
        if lowercased.hasPrefix("chore") || lowercased.hasPrefix("build") {
            return .chore
        }
        if lowercased.hasPrefix("style") {
            return .style
        }
        if lowercased.hasPrefix("perf") {
            return .performance
        }

        return .other
    }
}

enum CommitCategory: String, Codable {
    case feature
    case bugfix
    case refactor
    case documentation
    case test
    case chore
    case style
    case performance
    case merge
    case other

    var emoji: String {
        switch self {
        case .feature: return "✨"
        case .bugfix: return "🐛"
        case .refactor: return "♻️"
        case .documentation: return "📝"
        case .test: return "✅"
        case .chore: return "🔧"
        case .style: return "💄"
        case .performance: return "⚡️"
        case .merge: return "🔀"
        case .other: return "📦"
        }
    }
}
