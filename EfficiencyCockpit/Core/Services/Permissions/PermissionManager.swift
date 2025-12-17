import Foundation
import AppKit
import ApplicationServices

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityStatus: PermissionStatus = .unknown
    @Published private(set) var automationStatus: [String: PermissionStatus] = [:]
    @Published private(set) var fullDiskAccessStatus: PermissionStatus = .unknown
    @Published private(set) var screenRecordingStatus: PermissionStatus = .unknown

    static let trackedApps: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.microsoft.VSCodeInsiders": "Visual Studio Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.apple.dt.Xcode": "Xcode",
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm",
        "dev.warp.Warp-Stable": "Warp"
    ]

    init() {
        checkAllPermissions()
    }

    func checkAllPermissions() {
        checkAccessibilityPermission()
        checkScreenRecordingPermission()
        checkFullDiskAccess()
        for bundleId in Self.trackedApps.keys {
            checkAutomationPermission(for: bundleId)
        }
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .granted : .denied
    }

    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        accessibilityStatus = trusted ? .granted : .denied
        return trusted
    }

    // MARK: - Screen Recording

    func checkScreenRecordingPermission() {
        // Check by trying to get window names from CGWindowListCopyWindowInfo
        // Without permission, window names are masked/nil for other apps
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            screenRecordingStatus = .denied
            return
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier

        // Apps that reliably have window names when Screen Recording is enabled
        let reliableApps: Set<String> = ["Finder", "Dock", "SystemUIServer", "Window Server"]
        var foundReliableApp = false

        for window in windowList {
            guard let windowPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID != ourPID else {
                continue
            }

            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""

            // Check if this is a reliable app
            if reliableApps.contains(ownerName) {
                foundReliableApp = true
            }

            // If we can see a window name from another process, permission is granted
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                screenRecordingStatus = .granted
                return
            }
        }

        // If we found reliable apps but couldn't see any window names, permission is denied
        // If we didn't find reliable apps, it's unknown (unusual system state)
        screenRecordingStatus = foundReliableApp ? .denied : .unknown
    }

    // MARK: - Automation (AppleScript)

    func checkAutomationPermission(for bundleId: String) {
        // Note: There's no direct API to check automation permission status
        // We can only try to use it and see if it fails
        automationStatus[bundleId] = .unknown
    }

    func requestAutomationPermission(for bundleId: String) async -> Bool {
        // Attempt a simple AppleScript to trigger permission dialog
        guard let appName = Self.trackedApps[bundleId] else { return false }

        let script = """
        tell application "\(appName)"
            return name
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorInfo)

        let granted = result != nil && errorInfo == nil
        await MainActor.run {
            automationStatus[bundleId] = granted ? .granted : .denied
        }
        return granted
    }

    // MARK: - Full Disk Access

    func checkFullDiskAccess() {
        // Try to read a protected file to check Full Disk Access
        let testPath = "\(NSHomeDirectory())/Library/Application Support/com.apple.TCC/TCC.db"
        let canAccess = FileManager.default.isReadableFile(atPath: testPath)
        fullDiskAccessStatus = canAccess ? .granted : .denied
    }

    // MARK: - Open System Preferences

    func openSystemPreferences(for permission: PermissionType) {
        let url: URL?

        switch permission {
        case .accessibility:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .automation:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .fullDiskAccess:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .screenRecording:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }

        if let url = url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Capability Level

    var trackingCapability: TrackingCapability {
        if accessibilityStatus == .granted {
            let allAutomationGranted = automationStatus.values.allSatisfy { $0 == .granted }
            if allAutomationGranted && fullDiskAccessStatus == .granted {
                return .full
            }
            return .limited
        }
        return .minimal
    }
}

// MARK: - Types

enum PermissionStatus: String {
    case unknown
    case granted
    case denied
    case restricted

    var isGranted: Bool { self == .granted }

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }
}

enum PermissionType {
    case accessibility
    case automation
    case fullDiskAccess
    case screenRecording
}

enum TrackingCapability {
    case full      // All permissions granted
    case limited   // Some permissions missing (basic + partial)
    case minimal   // Only basic tracking (no accessibility)

    var description: String {
        switch self {
        case .full: return "Full Tracking"
        case .limited: return "Limited Tracking"
        case .minimal: return "Minimal Tracking"
        }
    }
}
