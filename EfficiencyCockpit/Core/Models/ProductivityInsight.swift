import Foundation
import SwiftData

@Model
final class ProductivityInsight {
    @Attribute(.unique) var id: UUID
    var generatedAt: Date
    var type: InsightType
    var title: String
    var content: String
    var periodStart: Date?
    var periodEnd: Date?
    var isRead: Bool
    var isDismissed: Bool

    init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        type: InsightType,
        title: String,
        content: String,
        periodStart: Date? = nil,
        periodEnd: Date? = nil,
        isRead: Bool = false,
        isDismissed: Bool = false
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.type = type
        self.title = title
        self.content = content
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.isRead = isRead
        self.isDismissed = isDismissed
    }
}

enum InsightType: String, Codable, CaseIterable {
    case focusPattern
    case contextSwitchWarning
    case productivityTrend
    case projectProgress
    case aiUsagePattern
    case recommendation

    var displayName: String {
        switch self {
        case .focusPattern: return "Focus Pattern"
        case .contextSwitchWarning: return "Context Switching"
        case .productivityTrend: return "Productivity Trend"
        case .projectProgress: return "Project Progress"
        case .aiUsagePattern: return "AI Usage"
        case .recommendation: return "Recommendation"
        }
    }

    var icon: String {
        switch self {
        case .focusPattern: return "eye"
        case .contextSwitchWarning: return "exclamationmark.triangle"
        case .productivityTrend: return "chart.line.uptrend.xyaxis"
        case .projectProgress: return "folder"
        case .aiUsagePattern: return "brain"
        case .recommendation: return "lightbulb"
        }
    }
}
