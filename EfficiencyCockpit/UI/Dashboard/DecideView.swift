import SwiftUI
import SwiftData

/// View for the Build/Buy Gatekeeper feature.
/// Records and tracks technical decisions with optional AI critique.
struct DecideView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Decision.timestamp, order: .reverse)
    private var decisions: [Decision]

    @State private var selectedDecision: Decision?
    @State private var showingNewDecision = false
    @State private var filterType: DecisionType?

    var body: some View {
        NavigationSplitView {
            decisionList
        } detail: {
            if let decision = selectedDecision {
                DecisionDetailView(decision: decision, modelContext: modelContext)
            } else {
                emptyState
            }
        }
        .navigationTitle("Decide")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingNewDecision = true }) {
                    Label("New Decision", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewDecision) {
            NewDecisionSheet(modelContext: modelContext)
        }
    }

    private var decisionList: some View {
        List(selection: $selectedDecision) {
            if filteredDecisions.isEmpty {
                ContentUnavailableView(
                    "No Decisions",
                    systemImage: "scale.3d",
                    description: Text("Record decisions to track and improve your choices")
                )
            } else {
                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        FilterChip(title: "All", isSelected: filterType == nil) {
                            filterType = nil
                        }
                        ForEach(DecisionType.allCases, id: \.self) { type in
                            FilterChip(title: type.displayName, isSelected: filterType == type) {
                                filterType = type
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                // Pending decisions
                let pending = filteredDecisions.filter { $0.isPending }
                if !pending.isEmpty {
                    Section("Pending (\(pending.count))") {
                        ForEach(pending) { decision in
                            DecisionRowView(decision: decision)
                                .tag(decision)
                        }
                    }
                }

                // Completed decisions
                let completed = filteredDecisions.filter { !$0.isPending }
                if !completed.isEmpty {
                    Section("Completed (\(completed.count))") {
                        ForEach(completed) { decision in
                            DecisionRowView(decision: decision)
                                .tag(decision)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "scale.3d")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("Build vs Buy Gatekeeper")
                .font(.title)
                .fontWeight(.bold)

            Text("Track your technical decisions to prevent over-building.\nGet AI critique to improve decision quality.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Text("Decision types:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(DecisionType.allCases.prefix(4), id: \.self) { type in
                    HStack {
                        Image(systemName: type.icon)
                            .frame(width: 20)
                        Text(type.displayName)
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Button(action: { showingNewDecision = true }) {
                Label("Record Decision", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredDecisions: [Decision] {
        if let filter = filterType {
            return decisions.filter { $0.decisionType == filter }
        }
        return decisions
    }
}

// MARK: - Decision Row

struct DecisionRowView: View {
    let decision: Decision

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: decision.decisionType.icon)
                    .foregroundColor(.accentColor)

                Text(decision.title)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                if let outcome = decision.outcome {
                    Image(systemName: outcome.icon)
                        .foregroundColor(outcome.color)
                }
            }

            Text(decision.problem)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Label(decision.decisionType.displayName, systemImage: decision.decisionType.icon)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if decision.aiCritique != nil {
                    Label("AI Reviewed", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.purple)
                }

                Spacer()

                Text(decision.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Decision Detail

struct DecisionDetailView: View {
    let decision: Decision
    let modelContext: ModelContext

    @StateObject private var claudeService = ClaudeService()
    @State private var showingOutcomeSheet = false
    @State private var isGeneratingCritique = false
    @State private var critiqueError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: decision.decisionType.icon)
                            .font(.title2)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading) {
                            Text(decision.title)
                                .font(.title2)
                                .fontWeight(.bold)

                            Text(decision.timestamp, style: .date)
                        }

                        Spacer()

                        if let outcome = decision.outcome {
                            OutcomeBadge(outcome: outcome)
                        }
                    }

                    if let project = decision.projectName {
                        Label(project, systemImage: "folder")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                // Problem
                sectionView(title: "Problem", content: decision.problem, icon: "questionmark.circle")

                // Frequency Assessment
                VStack(alignment: .leading, spacing: 8) {
                    Label("Frequency Assessment", systemImage: "clock.arrow.circlepath")
                        .font(.headline)

                    HStack {
                        Image(systemName: decision.frequency.icon)
                            .foregroundColor(.accentColor)
                        Text(decision.frequency.displayName)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal)

                    Text(decision.frequency.buildJustification)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                // Minimal Proof
                if let proof = decision.minimalProof {
                    sectionView(title: "Minimal Proof Required", content: proof, icon: "checkmark.shield")
                }

                // Options
                if !decision.optionsArray.isEmpty {
                    optionsSection
                }

                // Chosen option and rationale
                if let chosen = decision.chosenOption {
                    sectionView(title: "Chosen Option", content: chosen, icon: "checkmark.circle")
                }

                if let rationale = decision.rationale {
                    sectionView(title: "Rationale", content: rationale, icon: "text.quote")
                }

                // AI Critique
                if let critique = decision.aiCritique {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("AI Critique", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundColor(.purple)

                        Text(critique)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.purple.opacity(0.1))
                            .cornerRadius(8)
                    }
                } else if decision.critiqueRequested {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: generateCritique) {
                            if isGeneratingCritique {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Generating critique...")
                                }
                            } else {
                                Label("Generate AI Critique", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isGeneratingCritique)

                        if let error = critiqueError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }

                // Outcome notes
                if let notes = decision.outcomeNotes {
                    sectionView(title: "Outcome Notes", content: notes, icon: "note.text")
                }

                // Actions
                HStack {
                    if decision.isPending {
                        Button(action: { showingOutcomeSheet = true }) {
                            Label("Record Outcome", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Decision Details")
        .sheet(isPresented: $showingOutcomeSheet) {
            OutcomeSheet(decision: decision, modelContext: modelContext)
        }
    }

    private func sectionView(title: String, content: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)

            Text(content)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Options Considered", systemImage: "list.bullet")
                .font(.headline)

            ForEach(decision.optionsArray) { option in
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.name)
                        .fontWeight(.medium)

                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        if !option.pros.isEmpty {
                            Label("\(option.pros.count) pros", systemImage: "plus.circle")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        if !option.cons.isEmpty {
                            Label("\(option.cons.count) cons", systemImage: "minus.circle")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }

    private func generateCritique() {
        isGeneratingCritique = true
        critiqueError = nil

        Task {
            let prompt = buildCritiquePrompt()

            do {
                let critique = try await claudeService.runClaudeCLI(prompt: prompt)

                await MainActor.run {
                    decision.aiCritique = critique
                    decision.critiqueTimestamp = Date()
                    try? modelContext.save()
                    isGeneratingCritique = false
                }
            } catch {
                await MainActor.run {
                    critiqueError = error.localizedDescription
                    isGeneratingCritique = false
                }
            }
        }
    }

    private func buildCritiquePrompt() -> String {
        var prompt = """
        You are a technical decision reviewer. Analyze this decision and provide constructive critique.

        DECISION: \(decision.title)
        TYPE: \(decision.decisionType.displayName)
        PROBLEM: \(decision.problem)
        """

        if let chosen = decision.chosenOption {
            prompt += "\nCHOSEN OPTION: \(chosen)"
        }

        if let rationale = decision.rationale {
            prompt += "\nRATIONALE: \(rationale)"
        }

        let options = decision.optionsArray
        if !options.isEmpty {
            prompt += "\n\nOPTIONS CONSIDERED:"
            for option in options {
                prompt += "\n- \(option.name)"
                if !option.description.isEmpty {
                    prompt += ": \(option.description)"
                }
                if !option.pros.isEmpty {
                    prompt += " (Pros: \(option.pros.joined(separator: ", ")))"
                }
                if !option.cons.isEmpty {
                    prompt += " (Cons: \(option.cons.joined(separator: ", ")))"
                }
            }
        }

        prompt += """


        Provide a brief critique (2-3 paragraphs) covering:
        1. Strengths of this decision
        2. Potential risks or blind spots
        3. Suggestions for improvement or things to monitor

        Be constructive and specific.
        """

        return prompt
    }
}

// MARK: - Outcome Badge

struct OutcomeBadge: View {
    let outcome: DecisionOutcome

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: outcome.icon)
            Text(outcome.displayName)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(outcome.color.opacity(0.2))
        .foregroundColor(outcome.color)
        .cornerRadius(8)
    }
}

// MARK: - New Decision Sheet

struct NewDecisionSheet: View {
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var problem = ""
    @State private var decisionType: DecisionType = .buildVsBuy
    @State private var frequency: DecisionFrequency = .oneTime
    @State private var minimalProof = ""
    @State private var options: [DecisionOption] = []
    @State private var chosenOption = ""
    @State private var rationale = ""
    @State private var requestCritique = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Decision") {
                    TextField("Title", text: $title, prompt: Text("e.g., Use Redux vs Context"))

                    Picker("Type", selection: $decisionType) {
                        ForEach(DecisionType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.icon)
                                .tag(type)
                        }
                    }

                    TextField("Problem", text: $problem, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Frequency Assessment") {
                    Picker("How often does this problem occur?", selection: $frequency) {
                        ForEach(DecisionFrequency.allCases, id: \.self) { freq in
                            Label(freq.displayName, systemImage: freq.icon)
                                .tag(freq)
                        }
                    }

                    Text(frequency.buildJustification)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Minimal proof before committing", text: $minimalProof, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Options") {
                    ForEach($options) { $option in
                        OptionEditorRow(option: $option) {
                            if let index = options.firstIndex(where: { $0.id == option.id }) {
                                options.remove(at: index)
                            }
                        }
                    }

                    Button(action: addOption) {
                        Label("Add Option", systemImage: "plus")
                    }
                }

                Section("Decision") {
                    TextField("Chosen option", text: $chosenOption)
                    TextField("Rationale", text: $rationale, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("AI") {
                    Toggle("Request AI Critique", isOn: $requestCritique)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Decision")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveDecision()
                        dismiss()
                    }
                    .disabled(title.isEmpty || problem.isEmpty)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    private func addOption() {
        options.append(DecisionOption(name: "", description: ""))
    }

    private func saveDecision() {
        let decision = Decision(
            title: title,
            problem: problem,
            decisionType: decisionType,
            options: options.isEmpty ? nil : options,
            chosenOption: chosenOption.isEmpty ? nil : chosenOption,
            rationale: rationale.isEmpty ? nil : rationale,
            frequency: frequency,
            minimalProof: minimalProof.isEmpty ? nil : minimalProof,
            critiqueRequested: requestCritique
        )
        modelContext.insert(decision)
        try? modelContext.save()
    }
}

struct OptionEditorRow: View {
    @Binding var option: DecisionOption
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Option name", text: $option.name)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            TextField("Description", text: $option.description)
                .font(.subheadline)
        }
    }
}

// MARK: - Outcome Sheet

struct OutcomeSheet: View {
    let decision: Decision
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss

    @State private var outcome: DecisionOutcome = .successful
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Outcome") {
                    Picker("Result", selection: $outcome) {
                        ForEach(DecisionOutcome.allCases, id: \.self) { outcome in
                            Label(outcome.displayName, systemImage: outcome.icon)
                                .tag(outcome)
                        }
                    }

                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Record Outcome")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        decision.outcome = outcome
                        decision.outcomeNotes = notes.isEmpty ? nil : notes
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

#Preview {
    DecideView()
        .environmentObject(AppState.preview)
}
