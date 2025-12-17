import Foundation
import SwiftData

/// Analyzes work patterns to generate actionable digest insights.
/// Implements the "Push-Based Reminders" spec: detects stale work, missing next steps, unresolved decisions.
@MainActor
final class DigestAnalysisService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Stale Work Detection

    /// Find projects with old snapshots but no recent activity
    func detectStaleWork(thresholdDays: Int = 7) -> [StaleWorkItem] {
        let threshold = Calendar.current.date(byAdding: .day, value: -thresholdDays, to: Date()) ?? Date()

        // Get snapshots grouped by project
        let snapshotDescriptor = FetchDescriptor<ContextSnapshot>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        guard let allSnapshots = try? modelContext.fetch(snapshotDescriptor) else {
            return []
        }

        // Get recent activities
        let activityDescriptor = FetchDescriptor<Activity>(
            predicate: #Predicate { $0.timestamp >= threshold }
        )
        let recentActivities = (try? modelContext.fetch(activityDescriptor)) ?? []
        let recentProjectPaths = Set(recentActivities.compactMap { $0.projectPath })

        // Find snapshots for projects with no recent activity
        var staleItems: [StaleWorkItem] = []
        var seenProjects = Set<String>()

        for snapshot in allSnapshots {
            guard let projectPath = snapshot.projectPath,
                  !projectPath.isEmpty,
                  !seenProjects.contains(projectPath) else {
                continue
            }
            seenProjects.insert(projectPath)

            // Check if project has recent activity
            if !recentProjectPaths.contains(projectPath) && snapshot.timestamp < threshold {
                let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
                staleItems.append(StaleWorkItem(
                    projectPath: projectPath,
                    projectName: projectName,
                    lastSnapshot: snapshot,
                    daysSinceActivity: Calendar.current.dateComponents([.day], from: snapshot.timestamp, to: Date()).day ?? 0
                ))
            }
        }

        return staleItems.sorted { $0.daysSinceActivity > $1.daysSinceActivity }
    }

    // MARK: - Missing Next Steps Detection

    /// Find recent snapshots without next steps defined
    func findSnapshotsMissingNext(sinceDays: Int = 3) -> [ContextSnapshot] {
        let threshold = Calendar.current.date(byAdding: .day, value: -sinceDays, to: Date()) ?? Date()

        // Fetch recent snapshots and filter in memory
        // (SwiftData predicates with optional comparisons can crash)
        let descriptor = FetchDescriptor<ContextSnapshot>(
            predicate: #Predicate { snapshot in
                snapshot.timestamp >= threshold
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        let recentSnapshots = (try? modelContext.fetch(descriptor)) ?? []
        return recentSnapshots.filter { $0.nextSteps == nil || $0.nextSteps?.isEmpty == true }
    }

    // MARK: - Unresolved Decisions Detection

    /// Find decisions that are still pending
    func findUnresolvedDecisions(olderThanDays: Int = 7) -> [Decision] {
        let threshold = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date()) ?? Date()

        // Fetch all decisions older than threshold and filter in memory
        // (SwiftData predicates with optional enums can crash)
        let descriptor = FetchDescriptor<Decision>(
            predicate: #Predicate { decision in
                decision.timestamp < threshold
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )

        let allOldDecisions = (try? modelContext.fetch(descriptor)) ?? []
        return allOldDecisions.filter { $0.outcome == nil || $0.outcome == .pending }
    }

    /// Find decisions that requested critique but haven't received one
    func findDecisionsAwaitingCritique() -> [Decision] {
        // Fetch decisions with critique requested and filter in memory
        // (SwiftData predicates with optional comparisons can crash)
        let descriptor = FetchDescriptor<Decision>(
            predicate: #Predicate { decision in
                decision.critiqueRequested
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )

        let requestedDecisions = (try? modelContext.fetch(descriptor)) ?? []
        return requestedDecisions.filter { $0.aiCritique == nil }
    }

    // MARK: - Generate Full Digest

    func generateSmartDigest() -> SmartDigest {
        let staleWork = detectStaleWork(thresholdDays: 7)
        let missingNext = findSnapshotsMissingNext(sinceDays: 3)
        let unresolvedDecisions = findUnresolvedDecisions(olderThanDays: 7)
        let awaitingCritique = findDecisionsAwaitingCritique()

        // Calculate urgency score
        let urgencyScore = calculateUrgency(
            staleCount: staleWork.count,
            missingNextCount: missingNext.count,
            unresolvedCount: unresolvedDecisions.count,
            awaitingCritiqueCount: awaitingCritique.count
        )

        return SmartDigest(
            generatedAt: Date(),
            urgencyScore: urgencyScore,
            staleWork: staleWork,
            snapshotsMissingNext: missingNext,
            unresolvedDecisions: unresolvedDecisions,
            decisionsAwaitingCritique: awaitingCritique,
            summary: generateSummaryText(
                staleWork: staleWork,
                missingNext: missingNext,
                unresolvedDecisions: unresolvedDecisions
            )
        )
    }

    private func calculateUrgency(staleCount: Int, missingNextCount: Int, unresolvedCount: Int, awaitingCritiqueCount: Int) -> DigestUrgency {
        let total = staleCount + missingNextCount + unresolvedCount + awaitingCritiqueCount
        if total == 0 { return .clear }
        if total <= 2 { return .low }
        if total <= 5 { return .medium }
        return .high
    }

    private func generateSummaryText(
        staleWork: [StaleWorkItem],
        missingNext: [ContextSnapshot],
        unresolvedDecisions: [Decision]
    ) -> String {
        var lines: [String] = []

        if !staleWork.isEmpty {
            let projectNames = staleWork.prefix(3).map { $0.projectName }.joined(separator: ", ")
            lines.append("\(staleWork.count) stale project(s): \(projectNames)")
        }

        if !missingNext.isEmpty {
            lines.append("\(missingNext.count) snapshot(s) missing next steps")
        }

        if !unresolvedDecisions.isEmpty {
            lines.append("\(unresolvedDecisions.count) decision(s) awaiting resolution")
        }

        if lines.isEmpty {
            return "All clear! No pending items."
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Supporting Types

struct StaleWorkItem: Identifiable {
    var id: UUID { lastSnapshot.id }
    let projectPath: String
    let projectName: String
    let lastSnapshot: ContextSnapshot
    let daysSinceActivity: Int
}

struct SmartDigest {
    let generatedAt: Date
    let urgencyScore: DigestUrgency
    let staleWork: [StaleWorkItem]
    let snapshotsMissingNext: [ContextSnapshot]
    let unresolvedDecisions: [Decision]
    let decisionsAwaitingCritique: [Decision]
    let summary: String

    var isEmpty: Bool {
        staleWork.isEmpty && snapshotsMissingNext.isEmpty &&
        unresolvedDecisions.isEmpty && decisionsAwaitingCritique.isEmpty
    }

    var totalActionItems: Int {
        staleWork.count + snapshotsMissingNext.count +
        unresolvedDecisions.count + decisionsAwaitingCritique.count
    }
}

enum DigestUrgency: String {
    case clear = "clear"
    case low = "low"
    case medium = "medium"
    case high = "high"

    var displayName: String {
        switch self {
        case .clear: return "All Clear"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}
