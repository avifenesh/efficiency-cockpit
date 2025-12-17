// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EfficiencyCockpit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EfficiencyCockpit", targets: ["EfficiencyCockpit"]),
        .executable(name: "EfficiencyCockpitMCPServer", targets: ["EfficiencyCockpitMCPServer"])
    ],
    targets: [
        .executableTarget(
            name: "EfficiencyCockpit",
            path: "EfficiencyCockpit",
            exclude: ["Info.plist", "EfficiencyCockpit.entitlements", "Resources"],
            sources: [
                "App/EfficiencyCockpitApp.swift",
                "App/AppState.swift",
                "Core/AppIdentifiers.swift",
                "Core/Extensions/TimeInterval+Formatting.swift",
                "Core/Extensions/Data+JSON.swift",
                "Core/Models/Activity.swift",
                "Core/Models/AppSession.swift",
                "Core/Models/ProductivityInsight.swift",
                "Core/Models/DailySummary.swift",
                "Core/Models/ContextSnapshot.swift",
                "Core/Models/Decision.swift",
                "Core/Models/AIInteraction.swift",
                "Core/Models/ContentIndex.swift",
                "Core/Services/Permissions/PermissionManager.swift",
                "Core/Services/ActivityTracker/WindowTracker.swift",
                "Core/Services/ActivityTracker/ActivityTrackingService.swift",
                "Core/Services/ActivityTracker/BrowserTabTracker.swift",
                "Core/Services/ActivityTracker/IDEFileTracker.swift",
                "Core/Services/ActivityTracker/GitActivityTracker.swift",
                "Core/Services/ActivityTracker/AIToolUsageTracker.swift",
                "Core/Services/ClaudeService.swift",
                "Core/Services/NotificationService.swift",
                "Core/Services/ContentIndexingService.swift",
                "Core/Services/DigestAnalysisService.swift",
                "UI/MenuBar/MenuBarView.swift",
                "UI/Dashboard/DashboardView.swift",
                "UI/Dashboard/AskClaudeView.swift",
                "UI/Dashboard/ResumeView.swift",
                "UI/Dashboard/SearchView.swift",
                "UI/Dashboard/DecideView.swift",
                "UI/Dashboard/DigestView.swift",
                "UI/Settings/SettingsView.swift",
                "UI/Onboarding/OnboardingView.swift"
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .executableTarget(
            name: "EfficiencyCockpitMCPServer",
            path: "EfficiencyCockpitMCPServer",
            sources: ["main.swift", "DataAccess.swift"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
