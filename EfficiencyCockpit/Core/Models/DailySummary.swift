import Foundation
import SwiftData

@Model
final class DailySummary {
    @Attribute(.unique) var id: UUID
    var date: Date
    var totalActiveTime: TimeInterval
    var topAppsData: Data?  // Encoded [String: TimeInterval]
    var topProjectsData: Data?  // Encoded [String: TimeInterval]
    var focusSessionCount: Int
    var avgFocusSessionDuration: TimeInterval
    var contextSwitchCount: Int
    var aiToolTime: TimeInterval
    var productivityScore: Double

    var topApps: [String: TimeInterval] {
        get {
            guard let data = topAppsData else { return [:] }
            return (try? JSONDecoder().decode([String: TimeInterval].self, from: data)) ?? [:]
        }
        set {
            topAppsData = try? JSONEncoder().encode(newValue)
        }
    }

    var topProjects: [String: TimeInterval] {
        get {
            guard let data = topProjectsData else { return [:] }
            return (try? JSONDecoder().decode([String: TimeInterval].self, from: data)) ?? [:]
        }
        set {
            topProjectsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        totalActiveTime: TimeInterval = 0,
        focusSessionCount: Int = 0,
        avgFocusSessionDuration: TimeInterval = 0,
        contextSwitchCount: Int = 0,
        aiToolTime: TimeInterval = 0,
        productivityScore: Double = 0
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.totalActiveTime = totalActiveTime
        self.focusSessionCount = focusSessionCount
        self.avgFocusSessionDuration = avgFocusSessionDuration
        self.contextSwitchCount = contextSwitchCount
        self.aiToolTime = aiToolTime
        self.productivityScore = productivityScore
    }
}
