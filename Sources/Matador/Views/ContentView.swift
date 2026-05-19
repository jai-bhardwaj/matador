import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            // Single source of truth for window background — material gives the
            // subtle macOS depth without the harsh default off-white.
            Color.clear
                .background(.thickMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                UpdateBannerView(checker: UpdateChecker.shared)

                bodyContent
                    .frame(maxHeight: .infinity)

                StatusBarView()
            }

            if let msg = state.toastMessage {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ToastView(message: msg, isError: state.toastIsError)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 36)
                    }
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: state.toastMessage)
            }
        }
        .tint(Theme.brand)
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
        .sheet(isPresented: bindShowAddJobSheet()) {
            AddJobSheet()
        }
        .sheet(isPresented: bindShowSettingsSheet()) {
            SettingsSheet()
        }
        .sheet(item: bindSchedulerDetail()) { sched in
            SchedulerDetailSheet(scheduler: sched)
        }
        .preferredColorScheme(Settings.shared.appearance.colorScheme)
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

    @ViewBuilder
    private var bodyContent: some View {
        switch state.connectionState {
        case .connecting:
            ConnectingHero(message: "Connecting")
        case .reconnecting(let s, let attempt):
            ConnectingHero(message: "Reconnecting in \(s)s (attempt \(attempt))")
        case .disconnected(let msg):
            DisconnectedHero(message: msg)
        case .connected:
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
            } content: {
                JobListView()
                    .navigationSplitViewColumnWidth(min: 420, ideal: 520)
            } detail: {
                JobDetailView()
            }
            .background(.clear)
        }
    }

    // Bindings into @Observable state
    private func bindShowProfileSheet() -> Binding<Bool> {
        Binding(get: { state.showProfileSheet }, set: { state.showProfileSheet = $0 })
    }
    private func bindPasswordPrompt() -> Binding<PasswordPrompt?> {
        Binding(get: { state.passwordPrompt }, set: { state.passwordPrompt = $0 })
    }
    private func bindConfirm() -> Binding<ConfirmAction?> {
        Binding(get: { state.confirmAction }, set: { state.confirmAction = $0 })
    }
    private func bindShowAddJobSheet() -> Binding<Bool> {
        Binding(get: { state.showAddJobSheet }, set: { state.showAddJobSheet = $0 })
    }
    private func bindShowSettingsSheet() -> Binding<Bool> {
        Binding(get: { state.showSettingsSheet }, set: { state.showSettingsSheet = $0 })
    }
    private func bindSchedulerDetail() -> Binding<BullScheduler?> {
        Binding(get: { state.schedulerDetail }, set: { state.schedulerDetail = $0 })
    }
}

// MARK: - Hero states

struct ConnectingHero: View {
    @Environment(AppState.self) private var state
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 6) {
                Text(message)
                    .font(Theme.displayTitle)
                if let p = state.activeProfile {
                    Text(p.summary)
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DisconnectedHero: View {
    @Environment(AppState.self) private var state
    let message: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Theme.brandSoft)
                        .frame(width: 96, height: 96)
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Theme.brand)
                }

                VStack(spacing: 8) {
                    Text(headline)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                    Text(subhead)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                HStack(spacing: 10) {
                    Button {
                        state.editingProfile = nil
                        state.showProfileSheet = true
                    } label: {
                        Label("New Profile", systemImage: "plus.circle.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if state.activeProfile != nil {
                        Button {
                            Task { await state.connect() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    if let active = state.activeProfile {
                        Button {
                            state.editingProfile = active
                            state.showProfileSheet = true
                        } label: {
                            Label("Edit \(active.name)", systemImage: "pencil")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }

                if !state.profiles.isEmpty {
                    profileSwitcher
                        .padding(.top, 4)
                }
            }
            .padding(40)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        if message?.contains("connecting") == true { return "Couldn't reach Redis" }
        return "Not connected"
    }

    private var subhead: String {
        if let m = message, !m.isEmpty { return m }
        if let p = state.activeProfile {
            return "Configure \(p.name) (\(p.summary)) or add a new Redis profile to get started."
        }
        return "Add a Redis profile to start inspecting your BullMQ queues."
    }

    private var profileSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved profiles")
                .font(Theme.sectionLabel)
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                ForEach(state.profiles) { p in
                    Button {
                        Task { state.selectProfile(p) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(state.activeProfile?.id == p.id ? Theme.brand : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(p.name)
                                .font(.callout)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            (state.activeProfile?.id == p.id ? Theme.brandSoft : Color.secondary.opacity(0.10)),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
                .font(.callout)
            Text(message)
                .font(.system(.callout, design: .rounded))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
