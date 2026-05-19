import SwiftUI

@main
struct MatadorApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var showUpdateSheet = false

    var body: some Scene {
        WindowGroup(id: "main") {
            MatadorWindow()
                .frame(minWidth: 1000, minHeight: 640)
                .sheet(isPresented: $showUpdateSheet) {
                    UpdateSheetView(checker: UpdateChecker.shared)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1280, height: 800)
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
            CommandGroup(replacing: .newItem) {
                Button("New Window") { openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: .command)
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
        case .disconnected:
            return "Matador"
        }
    }
}
