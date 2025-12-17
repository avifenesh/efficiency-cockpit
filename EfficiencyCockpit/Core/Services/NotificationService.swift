import Foundation
import UserNotifications
import SwiftUI

/// Service for managing push notifications - digests and context-switch nudges
@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    @Published var isAuthorized = false
    @Published var settings: DigestSettings = DigestSettings.load()

    private let notificationCenter = UNUserNotificationCenter.current()

    private init() {
        Task {
            await checkAuthorization()
        }
    }

    // MARK: - Authorization

    /// Request notification permission
    func requestPermission() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            return granted
        } catch {
            print("[NotificationService] Permission request failed: \(error)")
            return false
        }
    }

    /// Check current authorization status
    func checkAuthorization() async {
        let settings = await notificationCenter.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    // MARK: - Digest Scheduling

    /// Schedule morning digest notification
    func scheduleMorningDigest() {
        // Always cancel first to prevent duplicates
        cancelNotification(identifier: "morning_digest")

        guard settings.morningDigestEnabled else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Morning Digest"
        content.body = "Here's your productivity summary for yesterday"
        content.sound = .default
        content.categoryIdentifier = "DIGEST"

        var dateComponents = DateComponents()
        dateComponents.hour = settings.morningDigestHour
        dateComponents.minute = settings.morningDigestMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "morning_digest", content: content, trigger: trigger)

        notificationCenter.add(request) { error in
            if let error = error {
                print("[NotificationService] Failed to schedule morning digest: \(error)")
            }
        }
    }

    /// Schedule end-of-day digest notification
    func scheduleEndOfDayDigest() {
        // Always cancel first to prevent duplicates
        cancelNotification(identifier: "eod_digest")

        guard settings.endOfDayDigestEnabled else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "End of Day Summary"
        content.body = "Review today's work and capture context before tomorrow"
        content.sound = .default
        content.categoryIdentifier = "DIGEST"

        var dateComponents = DateComponents()
        dateComponents.hour = settings.endOfDayDigestHour
        dateComponents.minute = settings.endOfDayDigestMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "eod_digest", content: content, trigger: trigger)

        notificationCenter.add(request) { error in
            if let error = error {
                print("[NotificationService] Failed to schedule EOD digest: \(error)")
            }
        }
    }

    /// Reschedule all notifications based on current settings
    func rescheduleAllNotifications() {
        scheduleMorningDigest()
        scheduleEndOfDayDigest()
    }

    /// Cancel a specific notification
    func cancelNotification(identifier: String) {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Cancel all notifications
    func cancelAllNotifications() {
        notificationCenter.removeAllPendingNotificationRequests()
    }

    // MARK: - Context Switch Nudges

    /// Send a context switch nudge notification
    func sendContextSwitchNudge(fromProject: String, toProject: String) {
        guard settings.contextSwitchNudgesEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Context Switch Detected"
        content.body = "You switched from \(fromProject) to \(toProject). Capture a snapshot?"
        content.sound = .default
        content.categoryIdentifier = "CONTEXT_SWITCH"
        content.userInfo = [
            "fromProject": fromProject,
            "toProject": toProject
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "context_switch_\(UUID().uuidString)", content: content, trigger: trigger)

        notificationCenter.add(request) { error in
            if let error = error {
                print("[NotificationService] Failed to send context switch nudge: \(error)")
            }
        }
    }

    // MARK: - Inactivity Snapshot Suggestion

    /// Send a suggestion to capture a snapshot after inactivity
    func sendInactivitySnapshotSuggestion(projectName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Time for a Snapshot?"
        content.body = "You've been away from \(projectName). Capture what you were working on?"
        content.sound = .default
        content.categoryIdentifier = "SNAPSHOT_SUGGESTION"
        content.userInfo = ["projectName": projectName]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "inactivity_snapshot_\(UUID().uuidString)", content: content, trigger: trigger)

        notificationCenter.add(request) { error in
            if let error = error {
                print("[NotificationService] Failed to send inactivity snapshot suggestion: \(error)")
            }
        }
    }

    // MARK: - Immediate Notifications

    /// Send an immediate notification
    func sendNotification(title: String, body: String, identifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let id = identifier ?? "immediate_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        notificationCenter.add(request) { error in
            if let error = error {
                print("[NotificationService] Failed to send notification: \(error)")
            }
        }
    }

    // MARK: - Settings Management

    func saveSettings() {
        settings.save()
        rescheduleAllNotifications()
    }
}

// MARK: - Digest Settings

struct DigestSettings: Codable {
    var morningDigestEnabled: Bool = false
    var morningDigestHour: Int = 9
    var morningDigestMinute: Int = 0

    var endOfDayDigestEnabled: Bool = false
    var endOfDayDigestHour: Int = 17
    var endOfDayDigestMinute: Int = 30

    var contextSwitchNudgesEnabled: Bool = true
    var contextSwitchThresholdMinutes: Int = 5

    private static let userDefaultsKey = "DigestSettings"

    static func load() -> DigestSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(DigestSettings.self, from: data) else {
            return DigestSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: DigestSettings.userDefaultsKey)
        }
    }

    var morningDigestTime: Date {
        get {
            Calendar.current.date(from: DateComponents(hour: morningDigestHour, minute: morningDigestMinute)) ?? Date()
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            morningDigestHour = components.hour ?? 9
            morningDigestMinute = components.minute ?? 0
        }
    }

    var endOfDayDigestTime: Date {
        get {
            Calendar.current.date(from: DateComponents(hour: endOfDayDigestHour, minute: endOfDayDigestMinute)) ?? Date()
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            endOfDayDigestHour = components.hour ?? 17
            endOfDayDigestMinute = components.minute ?? 30
        }
    }
}
