import Foundation
import AppKit
import ApplicationServices

struct WindowInfo {
    let windowId: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bundleId: String?
    let windowTitle: String?
    let bounds: CGRect
    let layer: Int
    let isOnScreen: Bool

    var isMainWindow: Bool {
        layer == 0
    }
}

final class WindowTracker {
    private var lastActiveWindow: WindowInfo?

    // MARK: - Window Information

    func getActiveWindow() -> WindowInfo? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let pid = frontApp.processIdentifier
        let bundleId = frontApp.bundleIdentifier
        let appName = frontApp.localizedName ?? "Unknown"

        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Try to find window by PID first (works with Screen Recording permission)
        for window in windowList {
            guard let windowPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid else {
                continue
            }

            let windowId = window[kCGWindowNumber as String] as? CGWindowID ?? 0
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? appName
            let windowTitle = window[kCGWindowName as String] as? String
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            return WindowInfo(
                windowId: windowId,
                ownerPID: windowPID,
                ownerName: ownerName,
                bundleId: bundleId,
                windowTitle: windowTitle,
                bounds: bounds,
                layer: layer,
                isOnScreen: true
            )
        }

        // Fallback: Try matching by owner name (for apps without Screen Recording permission)
        for window in windowList {
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            guard ownerName == appName else { continue }

            let windowId = window[kCGWindowNumber as String] as? CGWindowID ?? 0
            let windowPID = window[kCGWindowOwnerPID as String] as? pid_t ?? pid
            let windowTitle = window[kCGWindowName as String] as? String
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            return WindowInfo(
                windowId: windowId,
                ownerPID: windowPID,
                ownerName: ownerName,
                bundleId: bundleId,
                windowTitle: windowTitle,
                bounds: bounds,
                layer: layer,
                isOnScreen: true
            )
        }

        // Last fallback: Return basic info from frontmost app without window details
        return WindowInfo(
            windowId: 0,
            ownerPID: pid,
            ownerName: appName,
            bundleId: bundleId,
            windowTitle: nil,
            bounds: .zero,
            layer: 0,
            isOnScreen: true
        )
    }

    func getAllWindows() -> [WindowInfo] {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var windows: [WindowInfo] = []

        for window in windowList {
            let windowId = window[kCGWindowNumber as String] as? CGWindowID ?? 0
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let windowTitle = window[kCGWindowName as String] as? String
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]

            // Get bundle ID from running app
            let runningApps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier == ownerPID }
            let bundleId = runningApps.first?.bundleIdentifier

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            let info = WindowInfo(
                windowId: windowId,
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleId: bundleId,
                windowTitle: windowTitle,
                bounds: bounds,
                layer: layer,
                isOnScreen: true
            )

            windows.append(info)
        }

        return windows
    }

    // MARK: - Window Change Detection

    func checkForWindowChange() -> WindowInfo? {
        guard let current = getActiveWindow() else {
            return nil
        }

        // Check if window changed
        if let last = lastActiveWindow {
            if last.windowId != current.windowId ||
               last.bundleId != current.bundleId ||
               last.windowTitle != current.windowTitle {
                lastActiveWindow = current
                return current
            }
        } else {
            lastActiveWindow = current
            return current
        }

        return nil
    }

    // MARK: - Utility

    /// VSCode-like IDEs that use "filename — project" format
    private static let vscodeIDEs = AppIdentifiers.IDEs.vscodeStyle

    func extractFilePathFromTitle(_ title: String?, bundleId: String?) -> String? {
        guard let title = title, let bundleId = bundleId else { return nil }

        // VSCode/Cursor/Zed: "filename.ext — project-name"
        if Self.vscodeIDEs.contains(bundleId) {
            if let dashIndex = title.range(of: " — ") {
                let filename = String(title[..<dashIndex.lowerBound])
                // Only return if it looks like a filename
                if filename.contains(".") && !filename.hasPrefix("[") {
                    return filename
                }
            }
        }

        // Xcode: "filename.swift — ProjectName"
        if bundleId == AppIdentifiers.IDEs.xcode {
            if let dashIndex = title.range(of: " — ") {
                let filename = String(title[..<dashIndex.lowerBound])
                if filename.contains(".") {
                    return filename
                }
            }
        }

        // JetBrains: "project – filename.ext"
        if bundleId.hasPrefix(AppIdentifiers.IDEs.jetbrainsPrefix) {
            if let dashIndex = title.range(of: " – ") {
                let afterDash = String(title[dashIndex.upperBound...])
                if afterDash.contains(".") && !afterDash.contains("[") {
                    return afterDash.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return nil
    }

    func extractProjectFromTitle(_ title: String?, bundleId: String?) -> String? {
        guard let title = title, let bundleId = bundleId else { return nil }

        // VSCode/Cursor/Zed: "filename.ext — project-name"
        if Self.vscodeIDEs.contains(bundleId) {
            if let dashIndex = title.range(of: " — ") {
                var project = String(title[dashIndex.upperBound...])
                // Remove suffixes like "[Extension Development Host]"
                if let bracketIndex = project.range(of: " [") {
                    project = String(project[..<bracketIndex.lowerBound])
                }
                return project.trimmingCharacters(in: .whitespaces)
            }
        }

        // Xcode: "filename.swift — ProjectName"
        if bundleId == AppIdentifiers.IDEs.xcode {
            if let dashIndex = title.range(of: " — ") {
                let project = String(title[dashIndex.upperBound...])
                return project.trimmingCharacters(in: .whitespaces)
            }
        }

        // JetBrains: "project – filename.ext" or "project [path]"
        if bundleId.hasPrefix(AppIdentifiers.IDEs.jetbrainsPrefix) {
            var project = title
            if let dashIndex = title.range(of: " – ") {
                project = String(title[..<dashIndex.lowerBound])
            }
            if let bracketIndex = project.range(of: " [") {
                project = String(project[..<bracketIndex.lowerBound])
            }
            return project.trimmingCharacters(in: .whitespaces)
        }

        return nil
    }
}
