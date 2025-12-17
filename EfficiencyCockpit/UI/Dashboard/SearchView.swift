import SwiftUI
import SwiftData
import Combine

/// Unified search view for searching across all data types.
struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedTypes: Set<SearchResultType> = Set(SearchResultType.allCases)
    @State private var dateRange: DateRangeOption = .all
    @State private var isSearching = false
    @State private var cachedResults: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?

    // Query results - limited to recent items for performance
    @Query(sort: \Activity.timestamp, order: .reverse) private var activities: [Activity]
    @Query(sort: \ContextSnapshot.timestamp, order: .reverse) private var snapshots: [ContextSnapshot]
    @Query(sort: \Decision.timestamp, order: .reverse) private var decisions: [Decision]
    @Query(sort: \ProductivityInsight.generatedAt, order: .reverse) private var insights: [ProductivityInsight]
    @Query(sort: \AIInteraction.timestamp, order: .reverse) private var aiInteractions: [AIInteraction]

    private static let maxResultsPerType = 50
    private static let debounceDelay: TimeInterval = 0.3

    var body: some View {
        VStack(spacing: 0) {
            // Search bar and filters
            searchHeader

            Divider()

            // Results
            if debouncedSearchText.isEmpty {
                emptyState
            } else if cachedResults.isEmpty && !isSearching {
                noResultsState
            } else {
                resultsList
            }
        }
        .navigationTitle("Search")
        .onChange(of: searchText) { _, newValue in
            debounceSearch(newValue)
        }
        .onChange(of: selectedTypes) { _, _ in
            performSearch()
        }
        .onChange(of: dateRange) { _, _ in
            performSearch()
        }
    }

    private func debounceSearch(_ query: String) {
        isSearching = true
        // Cancel previous search task to prevent out-of-order results
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .seconds(Self.debounceDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedSearchText = query
                performSearch()
            }
        }
    }

    private func performSearch() {
        guard !debouncedSearchText.isEmpty else {
            cachedResults = []
            isSearching = false
            return
        }
        cachedResults = computeSearchResults()
        isSearching = false
    }

    private var searchHeader: some View {
        VStack(spacing: 12) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search activities, snapshots, decisions...", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // Type filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchResultType.allCases, id: \.self) { type in
                        FilterChip(
                            title: type.displayName,
                            isSelected: selectedTypes.contains(type)
                        ) {
                            if selectedTypes.contains(type) {
                                selectedTypes.remove(type)
                            } else {
                                selectedTypes.insert(type)
                            }
                        }
                    }

                    Divider()
                        .frame(height: 20)

                    // Date range picker
                    Menu {
                        ForEach(DateRangeOption.allCases, id: \.self) { option in
                            Button(option.displayName) {
                                dateRange = option
                            }
                        }
                    } label: {
                        Label(dateRange.displayName, systemImage: "calendar")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("Search Everything")
                .font(.title)
                .fontWeight(.bold)

            Text("Search across your activities, context snapshots,\ndecisions, and AI insights.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Try searching for:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(["A project name", "A file you worked on", "A decision you made"], id: \.self) { suggestion in
                    HStack {
                        Image(systemName: "arrow.right")
                            .font(.caption)
                        Text(suggestion)
                            .font(.callout)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No results found for \"\(searchText)\"")
        )
    }

    private var resultsList: some View {
        List {
            ForEach(groupedResults, id: \.type) { group in
                Section("\(group.type.displayName) (\(group.results.count))") {
                    ForEach(group.results) { result in
                        SearchResultRow(result: result)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Search Logic

    private func computeSearchResults() -> [SearchResult] {
        let query = debouncedSearchText.lowercased()
        let dateFilter = dateRange.dateRange
        var results: [SearchResult] = []
        var resultCount = 0
        let maxTotal = Self.maxResultsPerType * 4 // Cap total results

        // Search activities
        if selectedTypes.contains(.activity) {
            var typeCount = 0
            for activity in activities {
                guard typeCount < Self.maxResultsPerType, resultCount < maxTotal else { break }
                guard dateFilter.contains(activity.timestamp) else { continue }

                if matchesQuery(activity, query: query) {
                    results.append(SearchResult(
                        id: activity.id,
                        type: .activity,
                        title: activity.appName ?? "Unknown App",
                        subtitle: activity.windowTitle ?? "",
                        timestamp: activity.timestamp,
                        icon: activity.type.icon
                    ))
                    typeCount += 1
                    resultCount += 1
                }
            }
        }

        // Search snapshots
        if selectedTypes.contains(.snapshot) {
            var typeCount = 0
            for snapshot in snapshots {
                guard typeCount < Self.maxResultsPerType, resultCount < maxTotal else { break }
                guard dateFilter.contains(snapshot.timestamp) else { continue }

                if matchesQuery(snapshot, query: query) {
                    results.append(SearchResult(
                        id: snapshot.id,
                        type: .snapshot,
                        title: snapshot.title,
                        subtitle: snapshot.whatIWasDoing,
                        timestamp: snapshot.timestamp,
                        icon: "camera"
                    ))
                    typeCount += 1
                    resultCount += 1
                }
            }
        }

        // Search decisions
        if selectedTypes.contains(.decision) {
            var typeCount = 0
            for decision in decisions {
                guard typeCount < Self.maxResultsPerType, resultCount < maxTotal else { break }
                guard dateFilter.contains(decision.timestamp) else { continue }

                if matchesQuery(decision, query: query) {
                    results.append(SearchResult(
                        id: decision.id,
                        type: .decision,
                        title: decision.title,
                        subtitle: decision.problem,
                        timestamp: decision.timestamp,
                        icon: "scale.3d"
                    ))
                    typeCount += 1
                    resultCount += 1
                }
            }
        }

        // Search insights
        if selectedTypes.contains(.insight) {
            var typeCount = 0
            for insight in insights {
                guard typeCount < Self.maxResultsPerType, resultCount < maxTotal else { break }
                guard dateFilter.contains(insight.generatedAt) else { continue }

                if matchesQuery(insight, query: query) {
                    results.append(SearchResult(
                        id: insight.id,
                        type: .insight,
                        title: insight.title,
                        subtitle: insight.content,
                        timestamp: insight.generatedAt,
                        icon: "lightbulb"
                    ))
                    typeCount += 1
                    resultCount += 1
                }
            }
        }

        // Search AI history
        if selectedTypes.contains(.aiHistory) {
            var typeCount = 0
            for interaction in aiInteractions {
                guard typeCount < Self.maxResultsPerType, resultCount < maxTotal else { break }
                guard dateFilter.contains(interaction.timestamp) else { continue }

                if matchesQuery(interaction, query: query) {
                    results.append(SearchResult(
                        id: interaction.id,
                        type: .aiHistory,
                        title: interaction.actionTypeDisplayName,
                        subtitle: interaction.promptSummary,
                        timestamp: interaction.timestamp,
                        icon: interaction.actionTypeIcon
                    ))
                    typeCount += 1
                    resultCount += 1
                }
            }
        }

        return results.sorted { $0.timestamp > $1.timestamp }
    }

    private var groupedResults: [(type: SearchResultType, results: [SearchResult])] {
        let grouped = Dictionary(grouping: cachedResults) { $0.type }
        return SearchResultType.allCases.compactMap { type in
            guard let results = grouped[type], !results.isEmpty else { return nil }
            return (type: type, results: results)
        }
    }

    private func matchesQuery(_ activity: Activity, query: String) -> Bool {
        (activity.appName ?? "").lowercased().contains(query) ||
        (activity.windowTitle ?? "").lowercased().contains(query) ||
        (activity.projectPath ?? "").lowercased().contains(query) ||
        (activity.filePath ?? "").lowercased().contains(query)
    }

    private func matchesQuery(_ snapshot: ContextSnapshot, query: String) -> Bool {
        snapshot.title.lowercased().contains(query) ||
        snapshot.whatIWasDoing.lowercased().contains(query) ||
        (snapshot.projectPath ?? "").lowercased().contains(query) ||
        (snapshot.nextSteps ?? "").lowercased().contains(query)
    }

    private func matchesQuery(_ decision: Decision, query: String) -> Bool {
        decision.title.lowercased().contains(query) ||
        decision.problem.lowercased().contains(query) ||
        (decision.rationale ?? "").lowercased().contains(query) ||
        (decision.projectPath ?? "").lowercased().contains(query)
    }

    private func matchesQuery(_ insight: ProductivityInsight, query: String) -> Bool {
        insight.title.lowercased().contains(query) ||
        insight.content.lowercased().contains(query)
    }

    private func matchesQuery(_ interaction: AIInteraction, query: String) -> Bool {
        interaction.promptSummary.lowercased().contains(query) ||
        interaction.response.lowercased().contains(query) ||
        interaction.actionType.lowercased().contains(query) ||
        (interaction.projectPath ?? "").lowercased().contains(query)
    }
}

// MARK: - Search Result Types

enum SearchResultType: String, CaseIterable {
    case activity
    case snapshot
    case decision
    case insight
    case aiHistory

    var displayName: String {
        switch self {
        case .activity: return "Activities"
        case .snapshot: return "Snapshots"
        case .decision: return "Decisions"
        case .insight: return "Insights"
        case .aiHistory: return "AI History"
        }
    }

    var icon: String {
        switch self {
        case .activity: return "list.bullet"
        case .snapshot: return "camera"
        case .decision: return "scale.3d"
        case .insight: return "lightbulb"
        case .aiHistory: return "sparkles"
        }
    }
}

struct SearchResult: Identifiable {
    let id: UUID
    let type: SearchResultType
    let title: String
    let subtitle: String
    let timestamp: Date
    let icon: String
}

// MARK: - Date Range

enum DateRangeOption: String, CaseIterable {
    case all
    case today
    case week
    case month

    var displayName: String {
        switch self {
        case .all: return "All Time"
        case .today: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        }
    }

    var dateRange: ClosedRange<Date> {
        let now = Date()
        let calendar = Calendar.current

        switch self {
        case .all:
            return Date.distantPast...now
        case .today:
            return calendar.startOfDay(for: now)...now
        case .week:
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return weekAgo...now
        case .month:
            let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return monthAgo...now
        }
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.title)
                        .fontWeight(.medium)

                    Spacer()

                    Text(result.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(result.subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                Label(result.type.displayName, systemImage: result.type.icon)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SearchView()
        .environmentObject(AppState.preview)
}
