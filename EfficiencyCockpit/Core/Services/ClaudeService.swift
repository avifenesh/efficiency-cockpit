import Foundation
import SwiftUI

/// Service to interact with Claude CLI
@MainActor
final class ClaudeService: ObservableObject {
    @Published var isLoading = false
    @Published var lastResponse: String?
    @Published var lastError: String?

    private var currentTask: Process?

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
            return result
        } catch {
            let errorMessage = "Error: \(error.localizedDescription)"
            lastError = errorMessage
            return errorMessage
        }
    }

    /// Build activity context string from activities
    private func buildActivityContext(activities: [Activity]) -> String {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: now)!

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

        // Recent activities (last 20)
        context += "\n=== RECENT ACTIVITIES (last 20) ===\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        for activity in todayActivities.prefix(20) {
            let time = formatter.string(from: activity.timestamp)
            let app = activity.appName ?? "Unknown"
            let title = activity.windowTitle?.prefix(50) ?? ""
            context += "[\(time)] \(app): \(title)\n"
        }

        // Week summary
        context += "\n=== WEEK SUMMARY (last 7 days) ===\n"
        context += "Total activities this week: \(weekActivities.count)\n"
        let uniqueAppsWeek = Set(weekActivities.compactMap { $0.appName }).count
        context += "Unique apps used: \(uniqueAppsWeek)\n"

        return context
    }

    /// Run claude CLI with -p flag
    /// Uses direct process execution to avoid shell injection vulnerabilities
    private func runClaudeCLI(prompt: String) async throws -> String {
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
            process.arguments = ["-p", prompt]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Set environment for node-based CLI tools
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = NSHomeDirectory()
            // Add common paths where node/npm binaries might be
            // Note: NVM paths are handled explicitly in findClaudeBinary() since wildcards don't expand here
            let existingPath = env["PATH"] ?? ""
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(existingPath)"
            process.environment = env

            currentTask = process

            do {
                try process.run()

                DispatchQueue.global().async {
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    // Close file handles to prevent resource leaks
                    try? outputPipe.fileHandleForReading.close()
                    try? errorPipe.fileHandleForReading.close()

                    if process.terminationStatus == 0 {
                        let output = String(data: outputData, encoding: .utf8) ?? ""
                        continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: ClaudeError.executionFailed(errorOutput))
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Find claude binary in common locations
    private func findClaudeBinary() -> String? {
        let possiblePaths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/node_modules/.bin/claude"
        ]

        // Also check nvm versions
        let nvmBase = "\(NSHomeDirectory())/.nvm/versions/node"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            for version in contents {
                let path = "\(nvmBase)/\(version)/bin/claude"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: try which command
        let whichProcess = Process()
        let whichPipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["claude"]
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path = path, !path.isEmpty {
                    return path
                }
            }
        } catch {}

        return nil
    }

    /// Cancel current request
    func cancel() {
        currentTask?.terminate()
        currentTask = nil
        isLoading = false
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
            return "Claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code"
        }
    }
}
