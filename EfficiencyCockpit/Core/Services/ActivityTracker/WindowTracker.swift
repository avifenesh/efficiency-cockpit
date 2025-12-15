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
    private var windowChangeHandler: ((WindowInfo) -> Void)?

    // MARK: - Window Information

    func getActiveWindow() -> WindowInfo? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let pid = frontApp.processIdentifier
        let bundleId = frontApp.bundleIdentifier

        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Find the frontmost window belonging to the active app
        for window in windowList {
            guard let windowPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid else {
                continue
            }

            let windowId = window[kCGWindowNumber as String] as? CGWindowID ?? 0
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? "Unknown"
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

        return nil
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

    func extractFilePathFromTitle(_ title: String?, bundleId: String?) -> String? {
        guard let title = title else { return nil }

        // VSCode/Cursor: "filename.ext — project-name"
        if bundleId == "com.microsoft.VSCode" || bundleId == "com.todesktop.230313mzl4w4u92" {
            if let dashIndex = title.range(of: " — ") {
                let filename = String(title[..<dashIndex.lowerBound])
                return filename
            }
        }

        // Xcode: "filename.swift — ProjectName"
        if bundleId == "com.apple.dt.Xcode" {
            if let dashIndex = title.range(of: " — ") {
                let filename = String(title[..<dashIndex.lowerBound])
                return filename
            }
        }

        return nil
    }

    func extractProjectFromTitle(_ title: String?, bundleId: String?) -> String? {
        guard let title = title else { return nil }

        // VSCode/Cursor: "filename.ext — project-name"
        if bundleId == "com.microsoft.VSCode" || bundleId == "com.todesktop.230313mzl4w4u92" {
            if let dashIndex = title.range(of: " — ") {
                let project = String(title[dashIndex.upperBound...])
                return project.trimmingCharacters(in: .whitespaces)
            }
        }

        // Xcode: "filename.swift — ProjectName"
        if bundleId == "com.apple.dt.Xcode" {
            if let dashIndex = title.range(of: " — ") {
                let project = String(title[dashIndex.upperBound...])
                return project.trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }
}
