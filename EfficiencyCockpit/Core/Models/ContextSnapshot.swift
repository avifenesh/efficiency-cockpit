import Foundation
import SwiftData

/// Represents a saved snapshot of the user's working context.
/// Used for the "Resume" feature to quickly restore context after interruptions.
@Model
final class ContextSnapshot {
    @Attribute(.unique) var id: UUID

    /// When this snapshot was captured
    var timestamp: Date

    /// User-provided or auto-generated title for the snapshot
    var title: String

    /// Path to the project directory
    var projectPath: String?

    /// Current git branch at snapshot time
    var gitBranch: String?

    /// Last commit hash at snapshot time
    var gitCommitHash: String?

    /// List of uncommitted/dirty files (JSON-encoded)
    var gitDirtyFiles: Data?

    /// What the user was working on (core context)
    var whatIWasDoing: String

    /// Why they were doing it (goal/reasoning)
    var whyIWasDoingIt: String?

    /// What to do next when resuming
    var nextSteps: String?

    /// List of open files at snapshot time (JSON-encoded)
    var activeFiles: Data?

    /// List of running apps at snapshot time (JSON-encoded)
    var activeApps: Data?

    /// IDs of recent activities for reference (JSON-encoded)
    var recentActivityIds: Data?

    /// Whether this was captured automatically
    var isAutomatic: Bool

    /// Source of the snapshot
    var source: SnapshotSource

    /// User-provided tags (JSON-encoded)
    var tags: Data?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        title: String,
        projectPath: String? = nil,
        gitBranch: String? = nil,
        gitCommitHash: String? = nil,
        gitDirtyFiles: [String]? = nil,
        whatIWasDoing: String,
        whyIWasDoingIt: String? = nil,
        nextSteps: String? = nil,
        activeFiles: [String]? = nil,
        activeApps: [String]? = nil,
        recentActivityIds: [UUID]? = nil,
        isAutomatic: Bool = false,
        source: SnapshotSource = .manual,
        tags: [String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.gitCommitHash = gitCommitHash
        self.gitDirtyFiles = gitDirtyFiles?.jsonData
        self.whatIWasDoing = whatIWasDoing
        self.whyIWasDoingIt = whyIWasDoingIt
        self.nextSteps = nextSteps
        self.activeFiles = activeFiles?.jsonData
        self.activeApps = activeApps?.jsonData
        self.recentActivityIds = recentActivityIds?.map { $0.uuidString }.jsonData
        self.isAutomatic = isAutomatic
        self.source = source
        self.tags = tags?.jsonData
    }

    // MARK: - Computed Properties for JSON fields

    var gitDirtyFilesArray: [String] {
        gitDirtyFiles?.decodeJSON() ?? []
    }

    var activeFilesArray: [String] {
        activeFiles?.decodeJSON() ?? []
    }

    var activeAppsArray: [String] {
        activeApps?.decodeJSON() ?? []
    }

    var recentActivityIdsArray: [UUID] {
        let strings: [String] = recentActivityIds?.decodeJSON() ?? []
        return strings.compactMap { UUID(uuidString: $0) }
    }

    var tagsArray: [String] {
        tags?.decodeJSON() ?? []
    }

    /// Display-friendly project name
    var projectName: String? {
        guard let path = projectPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Time since this snapshot was taken
    var timeSinceSnapshot: TimeInterval {
        Date().timeIntervalSince(timestamp)
    }

    /// Human-readable time since snapshot
    var timeSinceSnapshotFormatted: String {
        let interval = timeSinceSnapshot
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}

// MARK: - Snapshot Source

enum SnapshotSource: String, Codable, CaseIterable {
    case manual = "manual"
    case scheduled = "scheduled"
    case contextSwitch = "contextSwitch"
    case endOfDay = "endOfDay"

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .scheduled: return "Scheduled"
        case .contextSwitch: return "Context Switch"
        case .endOfDay: return "End of Day"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "hand.tap"
        case .scheduled: return "clock"
        case .contextSwitch: return "arrow.triangle.swap"
        case .endOfDay: return "moon.stars"
        }
    }
}

