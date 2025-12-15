import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0

    private let steps = OnboardingStep.allCases

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            ProgressView(value: Double(currentStep + 1), total: Double(steps.count))
                .padding(.horizontal)
                .padding(.top)

            // Content
            Group {
                stepView(for: steps[currentStep])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if currentStep < steps.count - 1 {
                    Button("Continue") {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 450)
    }

    @ViewBuilder
    private func stepView(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            WelcomeStepView()
        case .accessibility:
            AccessibilityStepView(permissionManager: appState.permissionManager)
        case .screenRecording:
            ScreenRecordingStepView(permissionManager: appState.permissionManager)
        case .automation:
            AutomationStepView(permissionManager: appState.permissionManager)
        case .ready:
            ReadyStepView()
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        dismiss()
        appState.startTracking()
    }
}

enum OnboardingStep: CaseIterable {
    case welcome
    case accessibility
    case screenRecording
    case automation
    case ready
}

// MARK: - Welcome Step

struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)

            Text("Welcome to Efficiency Cockpit")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Track your productivity passively and get AI-powered insights about your work patterns.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 12) {
                FeatureRow(icon: "eye", title: "Passive Tracking", description: "Automatically tracks your apps, files, and projects")
                FeatureRow(icon: "brain", title: "AI Insights", description: "Get intelligent analysis via Claude Code integration")
                FeatureRow(icon: "lock.shield", title: "Privacy First", description: "All data stays on your Mac")
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Accessibility Step

struct AccessibilityStepView: View {
    @ObservedObject var permissionManager: PermissionManager
    @State private var hasRequestedPermission = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Accessibility Permission")
                .font(.title)
                .fontWeight(.bold)

            Text("This permission allows Efficiency Cockpit to see which apps and windows you're using.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 16) {
                HStack {
                    Text("Permission Status")
                    Spacer()
                    StatusBadge(status: permissionManager.accessibilityStatus)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                if permissionManager.accessibilityStatus != .granted {
                    Button("Grant Accessibility Permission") {
                        hasRequestedPermission = true
                        _ = permissionManager.requestAccessibilityPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if hasRequestedPermission {
                        Text("If a dialog didn't appear, click below to open System Settings manually.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Open System Settings") {
                            permissionManager.openSystemPreferences(for: .accessibility)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Permission granted!")
                            .fontWeight(.medium)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .onAppear {
            permissionManager.checkAccessibilityPermission()
        }
    }
}

// MARK: - Screen Recording Step

struct ScreenRecordingStepView: View {
    @ObservedObject var permissionManager: PermissionManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Screen Recording Permission")
                .font(.title)
                .fontWeight(.bold)

            Text("This permission is required to see window titles, which enables tracking of files you're editing, browser tabs, and project context.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 16) {
                HStack {
                    Text("Permission Status")
                    Spacer()
                    StatusBadge(status: permissionManager.screenRecordingStatus)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                if permissionManager.screenRecordingStatus != .granted {
                    Button("Open Screen Recording Settings") {
                        permissionManager.openSystemPreferences(for: .screenRecording)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("Add \"Efficiency Cockpit\" to the list of allowed apps, then click \"Refresh\" below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Refresh Status") {
                        permissionManager.checkScreenRecordingPermission()
                    }
                    .buttonStyle(.bordered)
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Permission granted!")
                            .fontWeight(.medium)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .onAppear {
            permissionManager.checkScreenRecordingPermission()
        }
    }
}

// MARK: - Automation Step

struct AutomationStepView: View {
    @ObservedObject var permissionManager: PermissionManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "gearshape.2")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Automation Permissions")
                .font(.title)
                .fontWeight(.bold)

            Text("These optional permissions allow deeper tracking of browser tabs and IDE files.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(PermissionManager.trackedApps.keys.sorted()), id: \.self) { bundleId in
                        let appName = PermissionManager.trackedApps[bundleId] ?? bundleId
                        let status = permissionManager.automationStatus[bundleId] ?? .unknown

                        HStack {
                            Text(appName)
                                .fontWeight(.medium)

                            Spacer()

                            StatusBadge(status: status)

                            if status != .granted {
                                Button("Request") {
                                    Task {
                                        await permissionManager.requestAutomationPermission(for: bundleId)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            .frame(maxHeight: 200)
            .padding(.horizontal)

            Text("You can skip this step and grant permissions later in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Ready Step

struct ReadyStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Efficiency Cockpit will now run in your menu bar and track your productivity in the background.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 16) {
                InfoRow(icon: "menubar.rectangle", text: "Find Efficiency Cockpit in your menu bar")
                InfoRow(icon: "chart.bar", text: "Open the Dashboard to see your activity")
                InfoRow(icon: "gear", text: "Adjust settings anytime from the menu")
                InfoRow(icon: "brain", text: "Connect Claude Code for AI insights")
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }
}

struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            Text(text)
                .font(.body)

            Spacer()
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState.preview)
}
