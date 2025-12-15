import Foundation
import AppKit

/// Tracks browser tab information using AppleScript
final class BrowserTabTracker {

    struct BrowserTab {
        let url: String
        let title: String
        let browserName: String
        let browserBundleId: String
    }

    // Supported browsers and their bundle IDs
    static let supportedBrowsers: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge"
    ]

    /// Get the active tab from the frontmost browser
    func getActiveTab(for bundleId: String) -> BrowserTab? {
        guard let browserName = Self.supportedBrowsers[bundleId] else {
            return nil
        }

        switch bundleId {
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac":
            return getChromiumTab(browserName: browserName, bundleId: bundleId)
        case "com.apple.Safari":
            return getSafariTab()
        case "company.thebrowser.Browser":
            return getArcTab()
        case "org.mozilla.firefox":
            return getFirefoxTab()
        default:
            return nil
        }
    }

    // MARK: - Chrome/Chromium-based browsers

    private func getChromiumTab(browserName: String, bundleId: String) -> BrowserTab? {
        let script = """
        tell application "\(browserName)"
            if (count of windows) > 0 then
                set activeTab to active tab of front window
                set tabURL to URL of activeTab
                set tabTitle to title of activeTab
                return tabURL & "||" & tabTitle
            end if
        end tell
        """

        guard let result = executeAppleScript(script) else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 2 else { return nil }

        return BrowserTab(
            url: parts[0],
            title: parts[1],
            browserName: browserName,
            browserBundleId: bundleId
        )
    }

    // MARK: - Safari

    private func getSafariTab() -> BrowserTab? {
        let script = """
        tell application "Safari"
            if (count of windows) > 0 then
                set currentTab to current tab of front window
                set tabURL to URL of currentTab
                set tabTitle to name of currentTab
                return tabURL & "||" & tabTitle
            end if
        end tell
        """

        guard let result = executeAppleScript(script) else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 2 else { return nil }

        return BrowserTab(
            url: parts[0],
            title: parts[1],
            browserName: "Safari",
            browserBundleId: "com.apple.Safari"
        )
    }

    // MARK: - Arc Browser

    private func getArcTab() -> BrowserTab? {
        // Arc uses a similar AppleScript interface to Chrome
        let script = """
        tell application "Arc"
            if (count of windows) > 0 then
                set activeTab to active tab of front window
                set tabURL to URL of activeTab
                set tabTitle to title of activeTab
                return tabURL & "||" & tabTitle
            end if
        end tell
        """

        guard let result = executeAppleScript(script) else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 2 else { return nil }

        return BrowserTab(
            url: parts[0],
            title: parts[1],
            browserName: "Arc",
            browserBundleId: "company.thebrowser.Browser"
        )
    }

    // MARK: - Firefox

    private func getFirefoxTab() -> BrowserTab? {
        // Firefox has limited AppleScript support - we can only get window title
        let script = """
        tell application "Firefox"
            if (count of windows) > 0 then
                set windowTitle to name of front window
                return windowTitle
            end if
        end tell
        """

        guard let result = executeAppleScript(script) else {
            return nil
        }

        // Firefox window title typically includes the page title
        return BrowserTab(
            url: "", // Firefox doesn't expose URL via AppleScript
            title: result,
            browserName: "Firefox",
            browserBundleId: "org.mozilla.firefox"
        )
    }

    // MARK: - AppleScript Execution

    private func executeAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return nil
        }

        let result = script.executeAndReturnError(&error)

        if let error = error {
            // Log error but don't crash - permission might not be granted
            print("AppleScript error: \(error)")
            return nil
        }

        return result.stringValue
    }

    // MARK: - URL Analysis

    /// Extract domain from URL
    func extractDomain(from url: String) -> String? {
        guard let urlObj = URL(string: url),
              let host = urlObj.host else {
            return nil
        }
        return host
    }

    /// Categorize URL for productivity tracking
    func categorizeURL(_ url: String) -> URLCategory {
        let lowercased = url.lowercased()

        // Development/Documentation
        if lowercased.contains("github.com") ||
           lowercased.contains("gitlab.com") ||
           lowercased.contains("stackoverflow.com") ||
           lowercased.contains("developer.apple.com") ||
           lowercased.contains("docs.") ||
           lowercased.contains("documentation") {
            return .development
        }

        // AI Tools
        if lowercased.contains("chat.openai.com") ||
           lowercased.contains("claude.ai") ||
           lowercased.contains("perplexity.ai") ||
           lowercased.contains("copilot") ||
           lowercased.contains("gemini.google.com") {
            return .aiTool
        }

        // Communication
        if lowercased.contains("slack.com") ||
           lowercased.contains("discord.com") ||
           lowercased.contains("teams.microsoft.com") ||
           lowercased.contains("mail.google.com") ||
           lowercased.contains("outlook") {
            return .communication
        }

        // Social Media
        if lowercased.contains("twitter.com") ||
           lowercased.contains("x.com") ||
           lowercased.contains("facebook.com") ||
           lowercased.contains("instagram.com") ||
           lowercased.contains("linkedin.com") ||
           lowercased.contains("reddit.com") {
            return .socialMedia
        }

        // Entertainment
        if lowercased.contains("youtube.com") ||
           lowercased.contains("netflix.com") ||
           lowercased.contains("twitch.tv") ||
           lowercased.contains("spotify.com") {
            return .entertainment
        }

        return .other
    }
}

enum URLCategory: String, Codable {
    case development
    case aiTool
    case communication
    case socialMedia
    case entertainment
    case other

    var isProductive: Bool {
        switch self {
        case .development, .aiTool:
            return true
        case .communication:
            return true // Could be work-related
        case .socialMedia, .entertainment:
            return false
        case .other:
            return true // Benefit of doubt
        }
    }
}
