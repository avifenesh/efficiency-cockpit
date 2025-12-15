import Foundation
import AppKit

/// Tracks usage of AI coding assistants and tools
final class AIToolUsageTracker {

    struct AIToolSession {
        let toolName: String
        let toolType: AIToolType
        let bundleId: String?
        let startTime: Date
        var duration: TimeInterval
        let context: AIToolContext?
    }

    struct AIToolContext {
        let conversationTopic: String?
        let codeLanguage: String?
        let projectName: String?
    }

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

    private var activeSessions: [String: AIToolSession] = [:]

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

    // MARK: - Session Management

    /// Start tracking an AI tool session
    func startSession(
        toolName: String,
        toolType: AIToolType,
        bundleId: String?,
        context: AIToolContext? = nil
    ) -> String {
        let sessionId = UUID().uuidString
        let session = AIToolSession(
            toolName: toolName,
            toolType: toolType,
            bundleId: bundleId,
            startTime: Date(),
            duration: 0,
            context: context
        )
        activeSessions[sessionId] = session
        return sessionId
    }

    /// End an AI tool session
    func endSession(_ sessionId: String) -> AIToolSession? {
        guard var session = activeSessions.removeValue(forKey: sessionId) else {
            return nil
        }
        session.duration = Date().timeIntervalSince(session.startTime)
        return session
    }

    /// Update session duration
    func updateSession(_ sessionId: String) {
        guard var session = activeSessions[sessionId] else { return }
        session.duration = Date().timeIntervalSince(session.startTime)
        activeSessions[sessionId] = session
    }

    /// Get active session for a tool
    func getActiveSession(for bundleId: String) -> (id: String, session: AIToolSession)? {
        for (id, session) in activeSessions {
            if session.bundleId == bundleId {
                return (id, session)
            }
        }
        return nil
    }

    // MARK: - Analysis

    /// Check if current activity is AI-assisted coding
    func isAIAssistedCoding(bundleId: String?, windowTitle: String?, url: String?) -> Bool {
        // Check desktop app
        if let bid = bundleId, detectAITool(bundleId: bid) != nil {
            return true
        }

        // Check browser URL
        if let url = url, detectAIToolFromURL(url) != nil {
            return true
        }

        // Check terminal for CLI tools
        if let bid = bundleId,
           Self.aiToolsByBundleId[bid]?.type == .cliTool,
           detectCLITool(from: windowTitle) != nil {
            return true
        }

        return false
    }

    /// Get all currently active AI tool sessions
    func getActiveSessions() -> [AIToolSession] {
        return Array(activeSessions.values)
    }

    /// Get total AI tool usage time today
    func getTotalAIUsageToday() -> TimeInterval {
        // This would typically query the database
        // For now, return sum of active sessions
        return activeSessions.values.reduce(0) { total, session in
            total + Date().timeIntervalSince(session.startTime)
        }
    }

    // MARK: - Context Extraction

    /// Try to extract context from window title
    func extractContext(from windowTitle: String?, bundleId: String?) -> AIToolContext? {
        guard let title = windowTitle else { return nil }

        var topic: String?
        var language: String?

        // Claude desktop shows conversation title
        if bundleId == "com.anthropic.claudefordesktop" {
            topic = title
        }

        // ChatGPT shows "ChatGPT - Topic"
        if bundleId == "com.openai.chat" {
            if let dashIndex = title.range(of: " - ") {
                topic = String(title[dashIndex.upperBound...])
            }
        }

        // Try to detect programming language mentions
        let languages = ["Swift", "Python", "JavaScript", "TypeScript", "Rust", "Go", "Java", "Ruby", "C++", "C#"]
        for lang in languages {
            if title.lowercased().contains(lang.lowercased()) {
                language = lang
                break
            }
        }

        if topic != nil || language != nil {
            return AIToolContext(
                conversationTopic: topic,
                codeLanguage: language,
                projectName: nil
            )
        }

        return nil
    }
}

// MARK: - AI Tool Statistics

extension AIToolUsageTracker {

    struct AIToolStats {
        let toolName: String
        let totalSessions: Int
        let totalDuration: TimeInterval
        let averageSessionDuration: TimeInterval
        let lastUsed: Date?
    }

    /// Calculate stats for a specific AI tool
    func calculateStats(for toolName: String, sessions: [AIToolSession]) -> AIToolStats {
        let toolSessions = sessions.filter { $0.toolName == toolName }
        let totalDuration = toolSessions.reduce(0) { $0 + $1.duration }
        let avgDuration = toolSessions.isEmpty ? 0 : totalDuration / Double(toolSessions.count)
        let lastUsed = toolSessions.max(by: { $0.startTime < $1.startTime })?.startTime

        return AIToolStats(
            toolName: toolName,
            totalSessions: toolSessions.count,
            totalDuration: totalDuration,
            averageSessionDuration: avgDuration,
            lastUsed: lastUsed
        )
    }
}
