import SwiftUI

@main
struct MatadorApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var showUpdateSheet = false

    var body: some Scene {
        WindowGroup(id: "main") {
            MatadorWindow()
                .frame(minWidth: 1080, minHeight: 700)
                .tint(Theme.brand)
                .sheet(isPresented: $showUpdateSheet) {
                    UpdateSheetView(checker: UpdateChecker.shared)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Matador") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: AppConstants.appName,
                        .applicationVersion: AppConstants.version,
                    ])
                }
                Divider()
                Button("Check for Updates…") {
                    Task {
                        await UpdateChecker.shared.checkForUpdates()
                        showUpdateSheet = true
                    }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .matadorSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Window") { openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Queue") {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .matadorRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Toggle Pause") {
                    NotificationCenter.default.post(name: .matadorTogglePause, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("Show Jobs") {
                    NotificationCenter.default.post(name: .matadorViewMode, object: QueueViewMode.jobs)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Show Schedulers") {
                    NotificationCenter.default.post(name: .matadorViewMode, object: QueueViewMode.schedulers)
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("Show Workers") {
                    NotificationCenter.default.post(name: .matadorViewMode, object: QueueViewMode.workers)
                }
                .keyboardShortcut("3", modifiers: .command)
                Button("Show Metrics") {
                    NotificationCenter.default.post(name: .matadorViewMode, object: QueueViewMode.metrics)
                }
                .keyboardShortcut("4", modifiers: .command)
            }
            CommandMenu("State") {
                ForEach(Array(JobState.allCases.enumerated()), id: \.element) { idx, s in
                    Button(s.label) {
                        NotificationCenter.default.post(name: .matadorJobState, object: s)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.option])
                }
            }
            CommandMenu("Job") {
                Button("Retry") { NotificationCenter.default.post(name: .matadorRetryJob, object: nil) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Promote") { NotificationCenter.default.post(name: .matadorPromoteJob, object: nil) }
                    .keyboardShortcut("u", modifiers: [.command])
                Button("Remove") { NotificationCenter.default.post(name: .matadorRemoveJob, object: nil) }
                    .keyboardShortcut(.delete, modifiers: [.command])
                Button("Add Job…") { NotificationCenter.default.post(name: .matadorAddJob, object: nil) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
    }
}

struct MatadorWindow: View {
    @State private var state = AppState()

    var body: some View {
        ContentView()
            .environment(state)
            .navigationTitle(windowTitle)
    }

    private var windowTitle: String {
        switch state.connectionState {
        case .connected:
            return state.activeProfile.map { "Matador — \($0.name)" } ?? AppConstants.appName
        case .connecting:
            return "Matador — Connecting…"
        case .reconnecting(let s, _):
            return "Matador — Reconnecting in \(s)s"
        case .disconnected:
            return "Matador"
        }
    }
}
