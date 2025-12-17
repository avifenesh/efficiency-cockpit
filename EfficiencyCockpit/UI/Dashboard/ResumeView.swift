import SwiftUI
import SwiftData

/// View for resuming work context - the core "Resume" feature.
/// Shows saved context snapshots and allows capturing new ones.
struct ResumeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ContextSnapshot.timestamp, order: .reverse)
    private var snapshots: [ContextSnapshot]

    @State private var selectedSnapshot: ContextSnapshot?
    @State private var showingCaptureSheet = false
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            snapshotList
        } detail: {
            if let snapshot = selectedSnapshot {
                SnapshotDetailView(snapshot: snapshot)
            } else {
                emptyState
            }
        }
        .navigationTitle("Resume")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingCaptureSheet = true }) {
                    Label("Capture Snapshot", systemImage: "camera.fill")
                }
            }
        }
        .sheet(isPresented: $showingCaptureSheet) {
            SnapshotCaptureSheet(modelContext: modelContext)
        }
    }

    private var snapshotList: some View {
        List(selection: $selectedSnapshot) {
            if filteredSnapshots.isEmpty {
                ContentUnavailableView(
                    "No Snapshots",
                    systemImage: "camera.metering.none",
                    description: Text("Capture a snapshot to save your work context")
                )
            } else {
                // Group by project
                ForEach(groupedSnapshots, id: \.project) { group in
                    Section(group.project ?? "No Project") {
                        ForEach(group.snapshots) { snapshot in
                            SnapshotRowView(snapshot: snapshot)
                                .tag(snapshot)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search snapshots")
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("Resume Your Work")
                .font(.title)
                .fontWeight(.bold)

            Text("Save snapshots of your work context to easily resume later.\nCapture what you're doing, why, and what's next.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Button(action: { showingCaptureSheet = true }) {
                Label("Capture Snapshot", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredSnapshots: [ContextSnapshot] {
        if searchText.isEmpty {
            return snapshots
        }
        return snapshots.filter { snapshot in
            snapshot.title.localizedCaseInsensitiveContains(searchText) ||
            snapshot.whatIWasDoing.localizedCaseInsensitiveContains(searchText) ||
            (snapshot.projectPath ?? "").localizedCaseInsensitiveContains(searchText) ||
            (snapshot.nextSteps ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedSnapshots: [(project: String?, snapshots: [ContextSnapshot])] {
        let grouped = Dictionary(grouping: filteredSnapshots) { $0.projectName }
        return grouped.map { (project: $0.key, snapshots: $0.value) }
            .sorted { ($0.snapshots.first?.timestamp ?? .distantPast) > ($1.snapshots.first?.timestamp ?? .distantPast) }
    }
}

// MARK: - Snapshot Row

struct SnapshotRowView: View {
    let snapshot: ContextSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: snapshot.source.icon)
                    .foregroundColor(.accentColor)

                Text(snapshot.title)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                Text(snapshot.timeSinceSnapshotFormatted)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(snapshot.whatIWasDoing)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let branch = snapshot.gitBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if !snapshot.activeFilesArray.isEmpty {
                    Label("\(snapshot.activeFilesArray.count) files", systemImage: "doc")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Snapshot Detail

struct SnapshotDetailView: View {
    let snapshot: ContextSnapshot
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: snapshot.source.icon)
                            .font(.title2)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading) {
                            Text(snapshot.title)
                                .font(.title2)
                                .fontWeight(.bold)

                            Text(snapshot.timestamp, style: .date) +
                            Text(" at ") +
                            Text(snapshot.timestamp, style: .time)
                        }
                    }

                    if let project = snapshot.projectName {
                        Label(project, systemImage: "folder")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                // What I Was Doing
                contextSection(title: "What I Was Doing", content: snapshot.whatIWasDoing, icon: "pencil")

                // Why
                if let why = snapshot.whyIWasDoingIt, !why.isEmpty {
                    contextSection(title: "Why", content: why, icon: "questionmark.circle")
                }

                // Next Steps
                if let nextSteps = snapshot.nextSteps, !nextSteps.isEmpty {
                    contextSection(title: "Next Steps", content: nextSteps, icon: "arrow.right.circle")
                }

                // Git Context
                if snapshot.gitBranch != nil {
                    gitContextSection
                }

                // Active Files
                if !snapshot.activeFilesArray.isEmpty {
                    filesSection
                }

                // Resume Button
                Button(action: resumeWork) {
                    Label("Resume This Work", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .navigationTitle("Snapshot Details")
    }

    private func contextSection(title: String, content: String, icon: String) -> some View {
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

    private var gitContextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Git Context", systemImage: "arrow.triangle.branch")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                if let branch = snapshot.gitBranch {
                    HStack {
                        Text("Branch:")
                            .foregroundColor(.secondary)
                        Text(branch)
                            .fontWeight(.medium)
                    }
                }

                if let hash = snapshot.gitCommitHash {
                    HStack {
                        Text("Commit:")
                            .foregroundColor(.secondary)
                        Text(String(hash.prefix(7)))
                            .font(.system(.body, design: .monospaced))
                    }
                }

                let dirtyFiles = snapshot.gitDirtyFilesArray
                if !dirtyFiles.isEmpty {
                    Text("Uncommitted files: \(dirtyFiles.count)")
                        .foregroundColor(.orange)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Active Files", systemImage: "doc.text")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshot.activeFilesArray.prefix(10), id: \.self) { file in
                    Text(URL(fileURLWithPath: file).lastPathComponent)
                        .font(.system(.body, design: .monospaced))
                }
                if snapshot.activeFilesArray.count > 10 {
                    Text("... and \(snapshot.activeFilesArray.count - 10) more")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
    }

    private func resumeWork() {
        // Open project in Finder/IDE if available
        if let projectPath = snapshot.projectPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: projectPath))
        }

        // Copy next steps to clipboard if available
        if let nextSteps = snapshot.nextSteps {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(nextSteps, forType: .string)
        }
    }
}

// MARK: - Capture Sheet

struct SnapshotCaptureSheet: View {
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var whatIWasDoing = ""
    @State private var whyIWasDoingIt = ""
    @State private var nextSteps = ""
    @State private var projectPath = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Context") {
                    TextField("Title", text: $title, prompt: Text("e.g., Implementing auth flow"))

                    TextField("What are you working on?", text: $whatIWasDoing, axis: .vertical)
                        .lineLimit(3...6)

                    TextField("Why? (optional)", text: $whyIWasDoingIt, axis: .vertical)
                        .lineLimit(2...4)

                    TextField("Next steps (optional)", text: $nextSteps, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Project") {
                    TextField("Project path (optional)", text: $projectPath)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Capture Snapshot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSnapshot()
                        dismiss()
                    }
                    .disabled(title.isEmpty || whatIWasDoing.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 400)
    }

    private func saveSnapshot() {
        let snapshot = ContextSnapshot(
            title: title,
            projectPath: projectPath.isEmpty ? nil : projectPath,
            whatIWasDoing: whatIWasDoing,
            whyIWasDoingIt: whyIWasDoingIt.isEmpty ? nil : whyIWasDoingIt,
            nextSteps: nextSteps.isEmpty ? nil : nextSteps,
            source: .manual
        )
        modelContext.insert(snapshot)
        try? modelContext.save()
    }
}

#Preview {
    ResumeView()
        .environmentObject(AppState.preview)
}
