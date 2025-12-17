import SwiftUI
import SwiftData

@main
struct EfficiencyCockpitApp: App {
    let sharedModelContainer: ModelContainer

    @StateObject private var appState: AppState

    init() {
        // Create model container first
        let schema = Schema([
            Activity.self,
            AppSession.self,
            ProductivityInsight.self,
            DailySummary.self,
            ContextSnapshot.self,
            Decision.self,
            AIInteraction.self,
            ContentIndex.self
        ])

        // Use a fixed location so MCP server can access the data
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Cannot access Application Support directory")
        }
        let storeDirectory = appSupport.appendingPathComponent("EfficiencyCockpit")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let storeURL = storeDirectory.appendingPathComponent("default.store")

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true
        )

        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        sharedModelContainer = container

        // Create AppState with the container's main context for consistency
        _appState = StateObject(wrappedValue: AppState(modelContext: container.mainContext))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Label("Efficiency Cockpit", systemImage: appState.isTracking ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
        }
        .menuBarExtraStyle(.window)
        .modelContainer(sharedModelContainer)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .modelContainer(sharedModelContainer)
        }

        Window("Dashboard", id: "dashboard") {
            DashboardView()
                .environmentObject(appState)
                .modelContainer(sharedModelContainer)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
    }
}
