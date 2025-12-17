import Foundation
import AppKit

/// Tracks usage of AI coding assistants and tools
final class AIToolUsageTracker {

    enum AIToolType: String, Codable, CaseIterable {
        case chatAssistant      // ChatGPT, Claude desktop
        case codeAssistant      // Copilot, Cursor AI
        case cliTool            // Claude Code, Codex, Gemini CLI
        case browserBased       // Claude.ai, ChatGPT web
        case idePlugin          // Copilot in VSCode

        var isProductiveCoding: Bool {
            switch self {
            case .codeAssistant, .cliTool, .idePlugin:
                return true
            case .chatAssistant, .browserBased:
                return true // Assuming used for work
            }
        }
    }

    // Known AI tools by bundle ID (only dedicated AI apps, not IDEs or terminals)
    static let aiToolsByBundleId: [String: (name: String, type: AIToolType)] = [
        // Desktop Apps - dedicated AI chat clients
        "com.anthropic.claudefordesktop": ("Claude", .chatAssistant),
        "com.openai.chat": ("ChatGPT", .chatAssistant),
        "ai.perplexity.mac": ("Perplexity", .chatAssistant),
        "com.lencx.chatgpt": ("ChatGPT (Tauri)", .chatAssistant),

        // Dedicated code assistants (NOT Cursor - it's an IDE first)
        "com.github.Copilot": ("GitHub Copilot", .codeAssistant)

        // Note: Cursor is handled as IDE, with AI detection from window title
        // Note: Terminals are handled separately, with AI CLI detection from title
    ]

    // Known AI tool URLs (for browser detection)
    static let aiToolURLPatterns: [(pattern: String, name: String, type: AIToolType)] = [
        ("chat.openai.com", "ChatGPT", .browserBased),
        ("claude.ai", "Claude", .browserBased),
        ("perplexity.ai", "Perplexity", .browserBased),
        ("gemini.google.com", "Gemini", .browserBased),
        ("copilot.github.com", "GitHub Copilot", .browserBased),
        ("github.com/copilot", "GitHub Copilot", .browserBased),
        ("bard.google.com", "Bard", .browserBased),
        ("poe.com", "Poe", .browserBased),
        ("you.com", "You.com", .browserBased),
        ("phind.com", "Phind", .browserBased),
        ("codeium.com", "Codeium", .browserBased),
        ("tabnine.com", "Tabnine", .browserBased)
    ]

    // CLI tool patterns (detected from terminal window titles)
    static let cliToolPatterns: [(pattern: String, name: String)] = [
        ("claude", "Claude Code"),
        ("codex", "Codex CLI"),
        ("gemini", "Gemini CLI"),
        ("copilot", "GitHub Copilot CLI"),
        ("aider", "Aider"),
        ("gpt", "GPT CLI")
    ]

    // MARK: - Detection

    /// Detect AI tool from app bundle ID
    func detectAITool(bundleId: String) -> (name: String, type: AIToolType)? {
        return Self.aiToolsByBundleId[bundleId]
    }

    /// Detect AI tool from browser URL
    func detectAIToolFromURL(_ url: String) -> (name: String, type: AIToolType)? {
        let lowercased = url.lowercased()
        for pattern in Self.aiToolURLPatterns {
            if lowercased.contains(pattern.pattern) {
                return (pattern.name, pattern.type)
            }
        }
        return nil
    }

    /// Detect AI CLI tool from terminal window title
    func detectCLITool(from windowTitle: String?) -> (name: String, type: AIToolType)? {
        guard let title = windowTitle?.lowercased() else { return nil }

        for pattern in Self.cliToolPatterns {
            if title.contains(pattern.pattern) {
                return (pattern.name, .cliTool)
            }
        }
        return nil
    }
}
