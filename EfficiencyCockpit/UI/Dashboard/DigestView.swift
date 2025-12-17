import SwiftUI
import SwiftData

/// View for the Smart Digest feature.
/// Shows stale work, missing next steps, unresolved decisions, and actions needed.
struct DigestView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var digest: SmartDigest?
    @State private var isLoading = false
    @State private var lastRefresh: Date?

    // Sheet state for editing snapshots
    @State private var selectedSnapshotForEdit: ContextSnapshot?
    @State private var showingNextStepsSheet = false
    @State private var nextStepsInput = ""

    // Sheet state for resolving decisions
    @State private var selectedDecisionForResolve: Decision?
    @State private var showingResolveSheet = false
    @State private var resolveOutcome: DecisionOutcome = .successful
    @State private var resolveNotes = ""

    // Critique generation state
    @State private var generatingCritiqueForDecision: Decision?
    @State private var isGeneratingCritique = false

    /// Lazily-created service instance (uses current modelContext)
    private var digestService: DigestAnalysisService {
        DigestAnalysisService(modelContext: modelContext)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header with urgency indicator
                headerSection

                if let digest = digest {
                    if digest.isEmpty {
                        allClearView
                    } else {
                        // Stale work section
                        if !digest.staleWork.isEmpty {
                            staleWorkSection(items: digest.staleWork)
                        }

                        // Missing next steps
                        if !digest.snapshotsMissingNext.isEmpty {
                            missingNextSection(snapshots: digest.snapshotsMissingNext)
                        }

                        // Unresolved decisions
                        if !digest.unresolvedDecisions.isEmpty {
                            unresolvedDecisionsSection(decisions: digest.unresolvedDecisions)
                        }

                        // Decisions awaiting critique
                        if !digest.decisionsAwaitingCritique.isEmpty {
                            awaitingCritiqueSection(decisions: digest.decisionsAwaitingCritique)
                        }
                    }
                } else if isLoading {
                    ProgressView("Analyzing...")
                        .padding()
                } else {
                    ContentUnavailableView(
                        "No Digest Available",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Tap refresh to generate your digest")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Digest")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: refreshDigest) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .onAppear {
            if digest == nil {
                refreshDigest()
            }
        }
        .sheet(isPresented: $showingNextStepsSheet) {
            nextStepsSheet
        }
        .sheet(isPresented: $showingResolveSheet) {
            resolveDecisionSheet
        }
    }

    // MARK: - Next Steps Sheet

    private var nextStepsSheet: some View {
        NavigationStack {
            Form {
                if let snapshot = selectedSnapshotForEdit {
                    Section("Snapshot") {
                        Text(snapshot.title)
                            .fontWeight(.medium)
                        Text(snapshot.whatIWasDoing)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Section("Next Steps") {
                        TextEditor(text: $nextStepsInput)
                            .frame(minHeight: 100)
                    }
                }
            }
            .navigationTitle("Add Next Steps")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingNextStepsSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveNextSteps()
                    }
                    .disabled(nextStepsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveNextSteps() {
        guard let snapshot = selectedSnapshotForEdit else { return }
        snapshot.nextSteps = nextStepsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
        showingNextStepsSheet = false
        refreshDigest()
    }

    // MARK: - Resolve Decision Sheet

    private var resolveDecisionSheet: some View {
        NavigationStack {
            Form {
                if let decision = selectedDecisionForResolve {
                    Section("Decision") {
                        Text(decision.title)
                            .fontWeight(.medium)
                        Text(decision.problem)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Section("Outcome") {
                        Picker("Outcome", selection: $resolveOutcome) {
                            ForEach(DecisionOutcome.allCases.filter { $0 != .pending }, id: \.self) { outcome in
                                Text(outcome.rawValue.capitalized).tag(outcome)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section("Notes") {
                        TextEditor(text: $resolveNotes)
                            .frame(minHeight: 80)
                    }
                }
            }
            .navigationTitle("Resolve Decision")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingResolveSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resolve") {
                        resolveDecision()
                    }
                }
            }
        }
    }

    private func resolveDecision() {
        guard let decision = selectedDecisionForResolve else { return }
        decision.outcome = resolveOutcome
        decision.outcomeNotes = resolveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
        showingResolveSheet = false
        refreshDigest()
    }

    // MARK: - Critique Generation

    private func generateCritique(for decision: Decision) {
        guard !isGeneratingCritique else { return }

        isGeneratingCritique = true
        generatingCritiqueForDecision = decision

        Task {
            let claudeService = ClaudeService()
            claudeService.configure(modelContext: modelContext)
            let critique = await claudeService.generateDecisionCritique(decision: decision)

            await MainActor.run {
                if let critique = critique {
                    decision.aiCritique = critique
                    try? modelContext.save()
                }
                isGeneratingCritique = false
                generatingCritiqueForDecision = nil
                refreshDigest()
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Smart Digest")
                        .font(.title2)
                        .fontWeight(.bold)

                    if let lastRefresh = lastRefresh {
                        Text("Updated \(lastRefresh, style: .relative) ago")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let digest = digest {
                    urgencyBadge(urgency: digest.urgencyScore)
                }
            }

            if let digest = digest, !digest.isEmpty {
                Text(digest.summary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }

    private func urgencyBadge(urgency: DigestUrgency) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(urgencyColor(urgency))
                .frame(width: 8, height: 8)
            Text(urgency.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(urgencyColor(urgency).opacity(0.2))
        .cornerRadius(16)
    }

    private func urgencyColor(_ urgency: DigestUrgency) -> Color {
        switch urgency {
        case .clear: return .green
        case .low: return .blue
        case .medium: return .yellow
        case .high: return .red
        }
    }

    private var allClearView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("All Clear!")
                .font(.title2)
                .fontWeight(.bold)

            Text("No stale work, all snapshots have next steps,\nand all decisions are resolved.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding(40)
    }

    private func staleWorkSection(items: [StaleWorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Stale Work (\(items.count))", systemImage: "clock.badge.exclamationmark")
                .font(.headline)
                .foregroundColor(.orange)

            ForEach(items) { item in
                staleWorkRow(item: item)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    private func staleWorkRow(item: StaleWorkItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.projectName)
                    .fontWeight(.medium)

                Text("Last snapshot: \(item.lastSnapshot.title)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("\(item.daysSinceActivity) days since activity")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            Spacer()

            Button("Resume") {
                openSnapshotInResumeView(item.lastSnapshot)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    private func openSnapshotInResumeView(_ snapshot: ContextSnapshot) {
        // Post notification to switch to resume view with this snapshot
        NotificationCenter.default.post(
            name: NSNotification.Name("OpenSnapshotInResume"),
            object: nil,
            userInfo: ["snapshotId": snapshot.id.uuidString]
        )
    }

    private func missingNextSection(snapshots: [ContextSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Missing Next Steps (\(snapshots.count))", systemImage: "arrow.right.circle")
                .font(.headline)
                .foregroundColor(.purple)

            ForEach(snapshots) { snapshot in
                missingNextRow(snapshot: snapshot)
            }
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(12)
    }

    private func missingNextRow(snapshot: ContextSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(snapshot.whatIWasDoing)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                Text(snapshot.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.purple)
            }

            Spacer()

            Button("Add Next") {
                selectedSnapshotForEdit = snapshot
                nextStepsInput = snapshot.nextSteps ?? ""
                showingNextStepsSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    private func unresolvedDecisionsSection(decisions: [Decision]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Unresolved Decisions (\(decisions.count))", systemImage: "scale.3d")
                .font(.headline)
                .foregroundColor(.red)

            ForEach(decisions) { decision in
                unresolvedDecisionRow(decision: decision)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
    }

    private func unresolvedDecisionRow(decision: Decision) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(decision.title)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(decision.problem)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                Text(decision.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            Spacer()

            Button("Resolve") {
                selectedDecisionForResolve = decision
                resolveOutcome = .successful
                resolveNotes = decision.outcomeNotes ?? ""
                showingResolveSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    private func awaitingCritiqueSection(decisions: [Decision]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Awaiting Critique (\(decisions.count))", systemImage: "sparkles")
                .font(.headline)
                .foregroundColor(.blue)

            ForEach(decisions) { decision in
                awaitingCritiqueRow(decision: decision)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    private func awaitingCritiqueRow(decision: Decision) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(decision.title)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("Critique requested")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(decision.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.blue)
            }

            Spacer()

            Button {
                generateCritique(for: decision)
            } label: {
                if isGeneratingCritique && generatingCritiqueForDecision?.id == decision.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Generate")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isGeneratingCritique)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    private func refreshDigest() {
        isLoading = true

        // Capture the service before entering Task to avoid environment access issues
        let service = digestService

        Task {
            let newDigest = service.generateSmartDigest()

            await MainActor.run {
                self.digest = newDigest
                self.lastRefresh = Date()
                self.isLoading = false
            }
        }
    }
}

#Preview {
    DigestView()
}
