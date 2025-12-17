import Foundation
import SwiftData
import SwiftUI

/// Represents a recorded decision for the Build/Buy Gatekeeper feature.
/// Helps track technical and strategic decisions with optional AI critique.
@Model
final class Decision {
    @Attribute(.unique) var id: UUID

    /// When this decision was recorded
    var timestamp: Date

    /// Short title for the decision
    var title: String

    /// The problem being solved
    var problem: String

    /// Type of decision
    var decisionType: DecisionType

    /// Available options (JSON-encoded [DecisionOption])
    var options: Data?

    /// The option that was chosen
    var chosenOption: String?

    /// Why this option was chosen
    var rationale: String?

    /// Related project path
    var projectPath: String?

    /// Related snapshot ID (if context was captured)
    var relatedSnapshotId: UUID?

    /// How often this problem occurs - key for build/buy analysis
    var frequency: DecisionFrequency

    /// Minimum validation needed before committing to the decision
    var minimalProof: String?

    /// Estimated time to implement (in seconds)
    var timeEstimate: Double?

    /// Actual time spent (filled in later)
    var actualTime: Double?

    /// AI-generated critique of the decision
    var aiCritique: String?

    /// Whether AI critique was requested
    var critiqueRequested: Bool

    /// Timestamp of when critique was received
    var critiqueTimestamp: Date?

    /// Outcome of the decision
    var outcome: DecisionOutcome?

    /// Notes about the outcome
    var outcomeNotes: String?

    /// When to review this decision
    var reviewDate: Date?

    /// User-provided tags (JSON-encoded)
    var tags: Data?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        title: String,
        problem: String,
        decisionType: DecisionType = .other,
        options: [DecisionOption]? = nil,
        chosenOption: String? = nil,
        rationale: String? = nil,
        projectPath: String? = nil,
        relatedSnapshotId: UUID? = nil,
        frequency: DecisionFrequency = .oneTime,
        minimalProof: String? = nil,
        timeEstimate: Double? = nil,
        critiqueRequested: Bool = false,
        tags: [String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.problem = problem
        self.decisionType = decisionType
        self.options = options?.jsonData
        self.chosenOption = chosenOption
        self.rationale = rationale
        self.projectPath = projectPath
        self.relatedSnapshotId = relatedSnapshotId
        self.frequency = frequency
        self.minimalProof = minimalProof
        self.timeEstimate = timeEstimate
        self.critiqueRequested = critiqueRequested
        self.tags = tags?.jsonData
    }

    // MARK: - Computed Properties

    var optionsArray: [DecisionOption] {
        options?.decodeJSON() ?? []
    }

    var tagsArray: [String] {
        tags?.decodeJSON() ?? []
    }

    /// Display-friendly project name
    var projectName: String? {
        guard let path = projectPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Formatted time estimate
    var timeEstimateFormatted: String? {
        guard let estimate = timeEstimate else { return nil }
        let hours = Int(estimate) / 3600
        let minutes = (Int(estimate) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Whether this decision is awaiting outcome
    var isPending: Bool {
        outcome == nil || outcome == .pending
    }

    /// Whether this decision needs review
    var needsReview: Bool {
        guard let reviewDate = reviewDate else { return false }
        return Date() >= reviewDate
    }
}

// MARK: - Decision Frequency

/// How often the problem occurs - key input for build/buy decisions
enum DecisionFrequency: String, Codable, CaseIterable {
    case oneTime = "oneTime"      // Will only happen once
    case rare = "rare"            // Few times per year
    case monthly = "monthly"      // Monthly occurrence
    case weekly = "weekly"        // Weekly occurrence
    case daily = "daily"          // Daily occurrence

    var displayName: String {
        switch self {
        case .oneTime: return "One-time"
        case .rare: return "Rare (few times/year)"
        case .monthly: return "Monthly"
        case .weekly: return "Weekly"
        case .daily: return "Daily"
        }
    }

    /// Guidance on whether building is justified given the frequency
    var buildJustification: String {
        switch self {
        case .oneTime: return "Low - one-time problems rarely justify building"
        case .rare: return "Low-Medium - consider buying or manual workaround"
        case .monthly: return "Medium - building may be justified if simple"
        case .weekly: return "Medium-High - automation likely worthwhile"
        case .daily: return "High - strong case for building"
        }
    }

    var icon: String {
        switch self {
        case .oneTime: return "1.circle"
        case .rare: return "calendar"
        case .monthly: return "calendar.badge.clock"
        case .weekly: return "calendar.day.timeline.left"
        case .daily: return "sunrise"
        }
    }
}

// MARK: - Decision Type

enum DecisionType: String, Codable, CaseIterable {
    case buildVsBuy = "buildVsBuy"
    case technicalApproach = "technicalApproach"
    case toolChoice = "toolChoice"
    case prioritization = "prioritization"
    case architecture = "architecture"
    case other = "other"

    var displayName: String {
        switch self {
        case .buildVsBuy: return "Build vs Buy"
        case .technicalApproach: return "Technical Approach"
        case .toolChoice: return "Tool Choice"
        case .prioritization: return "Prioritization"
        case .architecture: return "Architecture"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .buildVsBuy: return "hammer.fill"
        case .technicalApproach: return "wrench.and.screwdriver"
        case .toolChoice: return "shippingbox"
        case .prioritization: return "list.number"
        case .architecture: return "building.columns"
        case .other: return "questionmark.circle"
        }
    }
}

// MARK: - Decision Outcome

enum DecisionOutcome: String, Codable, CaseIterable {
    case successful = "successful"
    case partialSuccess = "partialSuccess"
    case failed = "failed"
    case abandoned = "abandoned"
    case pending = "pending"

    var displayName: String {
        switch self {
        case .successful: return "Successful"
        case .partialSuccess: return "Partial Success"
        case .failed: return "Failed"
        case .abandoned: return "Abandoned"
        case .pending: return "Pending"
        }
    }

    var icon: String {
        switch self {
        case .successful: return "checkmark.circle.fill"
        case .partialSuccess: return "checkmark.circle"
        case .failed: return "xmark.circle.fill"
        case .abandoned: return "trash.circle"
        case .pending: return "clock"
        }
    }

    var color: Color {
        switch self {
        case .successful: return .green
        case .partialSuccess: return .yellow
        case .failed: return .red
        case .abandoned: return .gray
        case .pending: return .blue
        }
    }
}

// MARK: - Decision Option

struct DecisionOption: Codable, Identifiable {
    var id: UUID
    var name: String
    var description: String
    var pros: [String]
    var cons: [String]
    var estimatedEffort: String?

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        pros: [String] = [],
        cons: [String] = [],
        estimatedEffort: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.pros = pros
        self.cons = cons
        self.estimatedEffort = estimatedEffort
    }
}

