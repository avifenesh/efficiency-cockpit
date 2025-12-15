import Foundation
import SwiftData

@Model
final class Activity {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var type: ActivityType
    var appBundleId: String?
    var appName: String?
    var windowTitle: String?
    var url: String?
    var filePath: String?
    var projectPath: String?
    var duration: TimeInterval?

    // Relationship to app session
    var session: AppSession?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: ActivityType,
        appBundleId: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        filePath: String? = nil,
        projectPath: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.filePath = filePath
        self.projectPath = projectPath
        self.duration = duration
    }
}

enum ActivityType: String, Codable, CaseIterable {
    case appSwitch
    case windowFocus
    case browserNavigation
    case fileOpen
    case fileEdit
    case terminalCommand
    case gitCommit
    case gitBranch
    case aiToolUse

    var displayName: String {
        switch self {
        case .appSwitch: return "App Switch"
        case .windowFocus: return "Window Focus"
        case .browserNavigation: return "Browser"
        case .fileOpen: return "File Open"
        case .fileEdit: return "File Edit"
        case .terminalCommand: return "Terminal"
        case .gitCommit: return "Git Commit"
        case .gitBranch: return "Git Branch"
        case .aiToolUse: return "AI Tool"
        }
    }

    var icon: String {
        switch self {
        case .appSwitch: return "app.badge"
        case .windowFocus: return "macwindow"
        case .browserNavigation: return "globe"
        case .fileOpen, .fileEdit: return "doc"
        case .terminalCommand: return "terminal"
        case .gitCommit, .gitBranch: return "arrow.triangle.branch"
        case .aiToolUse: return "brain"
        }
    }
}
