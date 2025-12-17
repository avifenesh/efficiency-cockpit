import Foundation
import SwiftUI
import SwiftData

/// Service to interact with Claude CLI
@MainActor
final class ClaudeService: ObservableObject {
    @Published var isLoading = false
    @Published var lastResponse: String?
    @Published var lastError: String?

    private var currentTask: Process?
    private var modelContext: ModelContext?

    /// Configure with model context for storing AI interactions
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Reusable date formatter for time display (DateFormatter is expensive to create)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Ask Claude a question with activity context
    func ask(_ question: String, activities: [Activity]) async -> String {
        isLoading = true
        lastError = nil

        defer { isLoading = false }

        // Build context from activities
        let activityContext = buildActivityContext(activities: activities)

        // Build the prompt with data context
        let contextPrompt = """
        You are an AI assistant helping analyze productivity data from the Efficiency Cockpit app.

        Here is the user's activity data:

        \(activityContext)

        Based on this data, please answer the following question:
        \(question)

        Provide a helpful, concise response based on the actual data provided.
        """

        do {
            let result = try await runClaudeCLI(prompt: contextPrompt)
            lastResponse = result

            // Store the AI interaction for searchability
            storeInteraction(
                promptSummary: question,
                fullPrompt: contextPrompt,
                actionType: "ask",
                response: result,
                contextType: "activities",
                projectPath: extractProjectPath(from: activities)
            )

            return result
        } catch {
            let errorMessage = "Error: \(error.localizedDescription)"
            lastError = errorMessage
            return errorMessage
        }
    }

    /// Extract the most common project path from activities
    private func extractProjectPath(from activities: [Activity]) -> String? {
        let projects = activities.compactMap { $0.projectPath }.filter { !$0.isEmpty }
        guard !projects.isEmpty else { return nil }
        let counts = Dictionary(grouping: projects) { $0 }.mapValues { $0.count }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    /// Store an AI interaction for later search and analysis
    private func storeInteraction(
        promptSummary: String,
        fullPrompt: String,
        actionType: String,
        response: String,
        contextType: String = "freeform",
        projectPath: String? = nil,
        relatedSnapshotId: UUID? = nil,
        relatedDecisionId: UUID? = nil
    ) {
        guard let modelContext = modelContext else { return }

        let interaction = AIInteraction(
            promptSummary: promptSummary,
            fullPrompt: fullPrompt.data(using: .utf8),
            actionType: actionType,
            response: response,
            wasSuccessful: true,
            contextType: contextType,
            relatedSnapshotId: relatedSnapshotId,
            relatedDecisionId: relatedDecisionId,
            projectPath: projectPath
        )

        modelContext.insert(interaction)
        try? modelContext.save()
    }

    /// Build activity context string from activities
    private func buildActivityContext(activities: [Activity]) -> String {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: now) ?? startOfToday

        let todayActivities = activities.filter { $0.timestamp >= startOfToday }
        let weekActivities = activities.filter { $0.timestamp >= startOfWeek }

        var context = "=== TODAY'S SUMMARY ===\n"
        context += "Total activities today: \(todayActivities.count)\n"

        // Apps used today
        let appsToday = Dictionary(grouping: todayActivities, by: { $0.appName ?? "Unknown" })
        context += "\nApps used today:\n"
        for (app, acts) in appsToday.sorted(by: { $0.value.count > $1.value.count }).prefix(10) {
            let totalTime = acts.compactMap { $0.duration }.reduce(0, +)
            let timeStr = totalTime > 0 ? " (\(Int(totalTime / 60)) minutes)" : ""
            context += "- \(app): \(acts.count) activities\(timeStr)\n"
        }

        // Projects worked on
        let projectsToday = Set(todayActivities.compactMap { $0.projectPath }).filter { !$0.isEmpty }
        if !projectsToday.isEmpty {
            context += "\nProjects worked on today:\n"
            for project in projectsToday.prefix(10) {
                let name = URL(fileURLWithPath: project).lastPathComponent
                context += "- \(name)\n"
            }
        }

        // Activity types
        let typeGroups = Dictionary(grouping: todayActivities, by: { $0.type })
        context += "\nActivity breakdown:\n"
        for (type, acts) in typeGroups.sorted(by: { $0.value.count > $1.value.count }) {
            context += "- \(type.displayName): \(acts.count)\n"
        }

        // Recent activities (last 10 to keep context manageable)
        context += "\n=== RECENT ACTIVITIES (last 10) ===\n"
        for activity in todayActivities.prefix(10) {
            let time = Self.timeFormatter.string(from: activity.timestamp)
            let app = activity.appName ?? "Unknown"
            let title = (activity.windowTitle ?? "").prefix(40)
            context += "[\(time)] \(app): \(title)\n"
        }

        // Week summary
        context += "\n=== WEEK SUMMARY (last 7 days) ===\n"
        context += "Total activities this week: \(weekActivities.count)\n"
        let uniqueAppsWeek = Set(weekActivities.compactMap { $0.appName }).count
        context += "Unique apps used: \(uniqueAppsWeek)\n"

        return context
    }

    /// Run claude CLI with prompt mode (-p) and text output format
    /// Uses direct process execution to avoid shell injection vulnerabilities
    func runClaudeCLI(prompt: String) async throws -> String {
        // Find claude binary - check common locations
        let claudePath = findClaudeBinary()
        guard let claudePath = claudePath else {
            throw ClaudeError.notInstalled
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            // Execute claude directly without shell interpolation
            // Since we use Process.arguments, the prompt is passed safely without shell escaping issues
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["-p", "--output-format", "text", prompt]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Set working directory to home to avoid trust issues
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

            // Set environment for node-based CLI tools
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = NSHomeDirectory()
            // Add common paths where node/npm binaries might be
            // Note: NVM paths are handled explicitly in findClaudeBinary() since wildcards don't expand here
            let existingPath = env["PATH"] ?? ""
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin:\(existingPath)"
            process.environment = env

            currentTask = process

            do {
                try process.run()

                DispatchQueue.global().async { [weak self] in
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    // Close file handles to prevent resource leaks
                    try? outputPipe.fileHandleForReading.close()
                    try? errorPipe.fileHandleForReading.close()

                    // Clean up currentTask reference
                    Task { @MainActor in
                        self?.currentTask = nil
                    }

                    if process.terminationStatus == 0 {
                        let output = String(data: outputData, encoding: .utf8) ?? ""
                        continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: ClaudeError.executionFailed(errorOutput))
                    }
                }
            } catch {
                currentTask = nil // Clear failed process reference
                // Close file handles to prevent resource leaks on error
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Find claude binary in common locations
    /// Prefers the native Bun binary at ~/.local/bin/claude over npm-installed versions
    private func findClaudeBinary() -> String? {
        // Check preferred paths first (native binary takes priority)
        let possiblePaths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: check nvm versions (npm-installed, less preferred)
        let nvmBase = "\(NSHomeDirectory())/.nvm/versions/node"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            for version in contents {
                let path = "\(nvmBase)/\(version)/bin/claude"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        // Fallback: try which command
        let whichProcess = Process()
        let whichPipe = Pipe()
        let fileHandle = whichPipe.fileHandleForReading

        defer {
            try? fileHandle.close()
        }

        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["claude"]
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = fileHandle.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path = path, !path.isEmpty {
                    return path
                }
            }
        } catch {
            print("[Claude] which command failed: \(error.localizedDescription)")
        }

        return nil
    }

    /// Cancel current request
    func cancel() {
        currentTask?.terminate()
        currentTask = nil
        isLoading = false
    }
}

// MARK: - Quick Actions

/// Quick actions for one-click AI assistance
enum QuickAction: String, CaseIterable {
    case summarize      // Summarize today/week
    case nextSteps      // Suggest next actions
    case debug          // Help debug current context
    case promptPack     // Generate context for new AI chat

    var displayName: String {
        switch self {
        case .summarize: return "Summarize"
        case .nextSteps: return "Next Steps"
        case .debug: return "Debug"
        case .promptPack: return "Prompt Pack"
        }
    }

    var icon: String {
        switch self {
        case .summarize: return "doc.text"
        case .nextSteps: return "arrow.right.circle"
        case .debug: return "ladybug"
        case .promptPack: return "doc.on.clipboard"
        }
    }

    var description: String {
        switch self {
        case .summarize: return "Get a summary of your work today"
        case .nextSteps: return "Suggest what to work on next"
        case .debug: return "Help debug current context"
        case .promptPack: return "Export context for Claude Code"
        }
    }
}

extension ClaudeService {
    /// Execute a quick action with the current activity context
    func executeQuickAction(_ action: QuickAction, activities: [Activity], snapshots: [ContextSnapshot] = [], decisions: [Decision] = []) async -> String {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let activityContext = buildActivityContext(activities: activities)
        let prompt = buildQuickActionPrompt(action: action, activityContext: activityContext, snapshots: snapshots, decisions: decisions)

        do {
            let result = try await runClaudeCLI(prompt: prompt)
            lastResponse = result

            // Store the AI interaction for searchability
            storeInteraction(
                promptSummary: action.displayName,
                fullPrompt: prompt,
                actionType: action.rawValue,
                response: result,
                contextType: "activities",
                projectPath: extractProjectPath(from: activities)
            )

            return result
        } catch {
            let errorMessage = "Error: \(error.localizedDescription)"
            lastError = errorMessage
            return errorMessage
        }
    }

    /// Build prompt for quick action
    private func buildQuickActionPrompt(action: QuickAction, activityContext: String, snapshots: [ContextSnapshot], decisions: [Decision]) -> String {
        var context = "You are an AI assistant helping with productivity analysis from the Efficiency Cockpit app.\n\n"
        context += "=== ACTIVITY DATA ===\n\(activityContext)\n"

        // Add recent snapshots context if available
        if !snapshots.isEmpty {
            context += "\n=== RECENT CONTEXT SNAPSHOTS ===\n"
            for snapshot in snapshots.prefix(5) {
                context += "[\(formatDate(snapshot.timestamp))] \(snapshot.title)\n"
                context += "  What: \(snapshot.whatIWasDoing)\n"
                if let why = snapshot.whyIWasDoingIt {
                    context += "  Why: \(why)\n"
                }
                if let next = snapshot.nextSteps {
                    context += "  Next: \(next)\n"
                }
            }
        }

        // Add recent decisions if available
        if !decisions.isEmpty {
            context += "\n=== RECENT DECISIONS ===\n"
            for decision in decisions.prefix(5) {
                context += "[\(formatDate(decision.timestamp))] \(decision.title) (\(decision.decisionType.displayName))\n"
                context += "  Problem: \(decision.problem)\n"
                if let chosen = decision.chosenOption {
                    context += "  Chosen: \(chosen)\n"
                }
            }
        }

        context += "\n=== TASK ===\n"

        switch action {
        case .summarize:
            context += """
            Provide a concise summary of today's work. Include:
            1. Main projects/tasks worked on
            2. Key accomplishments
            3. Time distribution across activities
            4. Any patterns noticed (focus time, context switches, etc.)

            Keep it brief but informative.
            """

        case .nextSteps:
            context += """
            Based on the recent activity and context snapshots, suggest the next steps. Consider:
            1. Any incomplete work from recent sessions
            2. Natural progression of current tasks
            3. Any blocked or pending items
            4. Priority suggestions based on patterns

            Provide 3-5 actionable next steps.
            """

        case .debug:
            context += """
            Help debug the current work context. Analyze:
            1. What seems to be the current focus/problem?
            2. Are there any signs of being stuck (repetitive activities, long gaps)?
            3. Suggest debugging approaches based on the context
            4. Identify any missing context that might help

            Be helpful and specific.
            """

        case .promptPack:
            context += """
            Generate a context package that can be used to onboard Claude Code to the current work. Include:
            1. Current project and task summary
            2. Recent context and decisions
            3. Key files/areas being worked on
            4. Suggested starting prompt for Claude Code

            Format as a ready-to-use context block that can be copied into a new conversation.
            """
        }

        return context
    }

    private func formatDate(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    /// Generate an AI critique for a decision
    func generateDecisionCritique(decision: Decision) async -> String? {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        var prompt = """
        You are an AI assistant helping analyze a build/buy/defer decision.

        === DECISION ===
        Title: \(decision.title)
        Type: \(decision.decisionType.displayName)
        Problem: \(decision.problem)

        """

        let optionsArray = decision.optionsArray
        if !optionsArray.isEmpty {
            prompt += "Options considered:\n"
            for (index, option) in optionsArray.enumerated() {
                prompt += "  \(index + 1). \(option.name)"
                if !option.description.isEmpty {
                    prompt += " - \(option.description)"
                }
                prompt += "\n"
            }
            prompt += "\n"
        }

        if let chosen = decision.chosenOption {
            prompt += "Chosen option: \(chosen)\n"
        }

        if let rationale = decision.rationale {
            prompt += "Rationale: \(rationale)\n"
        }

        prompt += "Expected frequency: \(decision.frequency.displayName)\n"

        if let minimalProof = decision.minimalProof, !minimalProof.isEmpty {
            prompt += "Minimal proof defined: \(minimalProof)\n"
        }

        prompt += """

        === TASK ===
        Provide a brief, constructive critique of this decision. Consider:
        1. Are there alternative approaches not considered?
        2. Is the chosen option aligned with the stated problem?
        3. Are there potential risks or blind spots?
        4. Is the minimal proof/success criteria well-defined?
        5. Any suggestions to improve the decision process?

        Keep it concise (3-5 bullet points) and actionable.
        """

        do {
            let result = try await runClaudeCLI(prompt: prompt)
            lastResponse = result

            // Store the AI interaction
            storeInteraction(
                promptSummary: "Critique: \(decision.title)",
                fullPrompt: prompt,
                actionType: "critique",
                response: result,
                contextType: "decision",
                projectPath: decision.projectPath,
                relatedDecisionId: decision.id
            )

            return result
        } catch {
            let errorMessage = "Error: \(error.localizedDescription)"
            lastError = errorMessage
            return nil
        }
    }
}

enum ClaudeError: LocalizedError {
    case executionFailed(String)
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return "Claude CLI error: \(message)"
        case .notInstalled:
            return "Claude CLI not found. Install Claude Code from https://claude.ai/download or run: npm install -g @anthropic-ai/claude-code"
        }
    }
}
