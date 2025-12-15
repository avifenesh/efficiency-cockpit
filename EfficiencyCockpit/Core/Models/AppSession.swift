import Foundation
import SwiftData

@Model
final class AppSession {
    @Attribute(.unique) var id: UUID
    var appBundleId: String
    var appName: String
    var startTime: Date
    var endTime: Date?
    var totalDuration: TimeInterval
    var isActive: Bool

    @Relationship(deleteRule: .cascade, inverse: \Activity.session)
    var activities: [Activity]?

    init(
        id: UUID = UUID(),
        appBundleId: String,
        appName: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        totalDuration: TimeInterval = 0,
        isActive: Bool = true
    ) {
        self.id = id
        self.appBundleId = appBundleId
        self.appName = appName
        self.startTime = startTime
        self.endTime = endTime
        self.totalDuration = totalDuration
        self.isActive = isActive
    }

    func end() {
        self.endTime = Date()
        self.isActive = false
        if let end = endTime {
            self.totalDuration = end.timeIntervalSince(startTime)
        }
    }
}

// Note: The session relationship is defined in Activity.swift
