import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            UpdateBannerView(checker: UpdateChecker.shared)

            ZStack {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                } content: {
                    JobListView()
                        .navigationSplitViewColumnWidth(min: 380, ideal: 460)
                } detail: {
                    JobDetailView()
                }

                if let msg = state.toastMessage {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ToastView(message: msg, isError: state.toastIsError)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 40)
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeOut(duration: 0.2), value: state.toastMessage)
                }
            }
            .frame(maxHeight: .infinity)

            StatusBarView()
        }
        .task {
            await state.connect()
            await UpdateChecker.shared.checkForUpdates()
        }
        .sheet(isPresented: bindShowProfileSheet()) {
            ProfileEditSheet(profile: state.editingProfile ?? RedisProfile())
        }
        .sheet(item: bindPasswordPrompt()) { prompt in
            PasswordPromptSheet(prompt: prompt)
        }
        .alert(item: bindConfirm()) { c in
            Alert(
                title: Text(c.title),
                message: Text(c.message),
                primaryButton: c.destructive
                    ? .destructive(Text("Confirm"), action: c.action)
                    : .default(Text("Confirm"), action: c.action),
                secondaryButton: .cancel()
            )
        }
    }

    // Bindings into @Observable state (Swift doesn't synthesise $ for @Environment)
    private func bindShowProfileSheet() -> Binding<Bool> {
        Binding(
            get: { state.showProfileSheet },
            set: { state.showProfileSheet = $0 }
        )
    }
    private func bindPasswordPrompt() -> Binding<PasswordPrompt?> {
        Binding(
            get: { state.passwordPrompt },
            set: { state.passwordPrompt = $0 }
        )
    }
    private func bindConfirm() -> Binding<ConfirmAction?> {
        Binding(
            get: { state.confirmAction },
            set: { state.confirmAction = $0 }
        )
    }
}

struct ToastView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(message)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}
