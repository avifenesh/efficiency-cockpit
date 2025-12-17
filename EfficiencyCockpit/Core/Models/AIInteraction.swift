import Foundation
import SwiftData

/// Stores every AI interaction for searchability and learning.
/// Enables searching past AI outputs and building context for future queries.
@Model
final class AIInteraction {
    @Attribute(.unique) var id: UUID

    /// When this interaction occurred
    var timestamp: Date

    /// First 200 chars of prompt for display
    var promptSummary: String

    /// Full prompt stored as UTF-8 Data (for large prompts)
    var fullPrompt: Data?

    /// Type of action: "ask", "summarize", "nextSteps", "debug", "promptPack", "critique"
    var actionType: String

    /// The AI's response
    var response: String

    /// Length of response for quick filtering
    var responseLength: Int

    /// Whether the AI call succeeded
    var wasSuccessful: Bool

    /// Context type: "activities", "snapshot", "decision", "freeform"
    var contextType: String

    /// Related snapshot ID if applicable
    var relatedSnapshotId: UUID?

    /// Related decision ID if applicable
    var relatedDecisionId: UUID?

    /// Project path for filtering
    var projectPath: String?

    /// User feedback: was this response helpful?
    var wasHelpful: Bool?

    /// User-provided feedback text
    var userFeedback: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        promptSummary: String,
        fullPrompt: Data? = nil,
        actionType: String,
        response: String,
        wasSuccessful: Bool = true,
        contextType: String = "freeform",
        relatedSnapshotId: UUID? = nil,
        relatedDecisionId: UUID? = nil,
        projectPath: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.promptSummary = String(promptSummary.prefix(200))
        self.fullPrompt = fullPrompt
        self.actionType = actionType
        self.response = response
        self.responseLength = response.count
        self.wasSuccessful = wasSuccessful
        self.contextType = contextType
        self.relatedSnapshotId = relatedSnapshotId
        self.relatedDecisionId = relatedDecisionId
        self.projectPath = projectPath
    }

    // MARK: - Computed Properties

    /// Display-friendly project name
    var projectName: String? {
        guard let path = projectPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Time since this interaction
    var timeSinceInteraction: TimeInterval {
        Date().timeIntervalSince(timestamp)
    }

    /// Human-readable time since interaction
    var timeSinceInteractionFormatted: String {
        let interval = timeSinceInteraction
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

    /// Display name for action type
    var actionTypeDisplayName: String {
        switch actionType {
        case "ask": return "Question"
        case "summarize": return "Summary"
        case "nextSteps": return "Next Steps"
        case "debug": return "Debug"
        case "promptPack": return "Prompt Pack"
        case "critique": return "Critique"
        default: return actionType.capitalized
        }
    }

    /// Icon for action type
    var actionTypeIcon: String {
        switch actionType {
        case "ask": return "questionmark.bubble"
        case "summarize": return "doc.text"
        case "nextSteps": return "arrow.right.circle"
        case "debug": return "ant"
        case "promptPack": return "doc.on.doc"
        case "critique": return "checkmark.seal"
        default: return "sparkles"
        }
    }
}
