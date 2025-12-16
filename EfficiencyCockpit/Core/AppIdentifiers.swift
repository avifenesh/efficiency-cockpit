import Foundation

/// Centralized bundle identifiers for tracked applications
enum AppIdentifiers {

    // MARK: - Browsers

    enum Browsers {
        static let chrome = "com.google.Chrome"
        static let chromeCanary = "com.google.Chrome.canary"
        static let safari = "com.apple.Safari"
        static let arc = "company.thebrowser.Browser"
        static let firefox = "org.mozilla.firefox"
        static let edge = "com.microsoft.edgemac"
        static let brave = "com.brave.Browser"

        static let all: Set<String> = [
            chrome, chromeCanary, safari, arc, firefox, edge, brave
        ]
    }

    // MARK: - IDEs and Editors

    enum IDEs {
        static let vscode = "com.microsoft.VSCode"
        static let vscodeInsiders = "com.microsoft.VSCodeInsiders"
        static let cursor = "com.todesktop.230313mzl4w4u92"
        static let xcode = "com.apple.dt.Xcode"
        static let sublimeText = "com.sublimetext.4"
        static let sublimeText3 = "com.sublimetext.3"
        static let zed = "dev.zed.Zed"

        /// VSCode-style IDEs that use "filename — project" format
        static let vscodeStyle: Set<String> = [
            vscode, vscodeInsiders, cursor, zed
        ]

        /// JetBrains IDEs use "project – filename" format
        static let jetbrainsPrefix = "com.jetbrains."

        static let all: Set<String> = [
            vscode, vscodeInsiders, cursor, xcode, sublimeText, sublimeText3, zed
        ]
    }

    // MARK: - Terminals

    enum Terminals {
        static let terminal = "com.apple.Terminal"
        static let iterm2 = "com.googlecode.iterm2"
        static let warp = "dev.warp.Warp-Stable"
        static let kitty = "net.kovidgoyal.kitty"
        static let hyper = "co.zeit.hyper"
        static let wezterm = "com.github.wez.wezterm"
        static let alacritty = "io.alacritty"

        static let all: Set<String> = [
            terminal, iterm2, warp, kitty, hyper, wezterm, alacritty
        ]
    }

    // MARK: - AI Tools

    enum AITools {
        static let claude = "com.anthropic.claudefordesktop"
        static let chatgpt = "com.openai.chat"
        static let perplexity = "ai.perplexity.mac"
        static let chatgptTauri = "com.lencx.chatgpt"
        static let githubCopilot = "com.github.Copilot"

        static let all: Set<String> = [
            claude, chatgpt, perplexity, chatgptTauri, githubCopilot
        ]
    }

    // MARK: - Communication

    enum Communication {
        static let slack = "com.tinyspeck.slackmacgap"
        static let discord = "com.hnc.Discord"
        static let zoom = "us.zoom.xos"
        static let teams = "com.microsoft.teams"

        static let all: Set<String> = [
            slack, discord, zoom, teams
        ]
    }
}
