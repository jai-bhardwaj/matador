import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            profilePicker
            Divider()
            queueList
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Profile picker

    private var profilePicker: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(state.profiles) { p in
                    Button {
                        Task { state.selectProfile(p) }
                    } label: {
                        HStack {
                            Text(p.name)
                            if state.activeProfile?.id == p.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button("New Profile…") {
                    state.editingProfile = nil
                    state.showProfileSheet = true
                }
                if let active = state.activeProfile {
                    Button("Edit \(active.name)…") {
                        state.editingProfile = active
                        state.showProfileSheet = true
                    }
                    Button("Delete \(active.name)", role: .destructive) {
                        state.confirmAction = ConfirmAction(
                            title: "Delete profile?",
                            message: "Remove \(active.name) (\(active.summary)) and its saved password.",
                            destructive: true,
                            action: { state.deleteProfile(active) }
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 8, height: 8)
                    Text(state.activeProfile?.name ?? "No profile")
                        .font(.system(.body, design: .default).weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var connectionDotColor: Color {
        switch state.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        }
    }

    // MARK: Queue list

    private var queueList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queues")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.queues.isEmpty {
                    Text("\(state.queues.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Button {
                    Task { await state.refreshQueues() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh queues")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            TextField("Filter queues…", text: bindQueueSearch())
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            List(selection: bindSelectedQueueID()) {
                ForEach(filteredQueues) { q in
                    QueueRow(queue: q)
                        .tag(q.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await state.selectQueue(q) }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var filteredQueues: [BullQueue] {
        let s = state.queueSearch.lowercased()
        if s.isEmpty { return state.queues }
        return state.queues.filter { $0.name.lowercased().contains(s) }
    }

    private func bindQueueSearch() -> Binding<String> {
        Binding(get: { state.queueSearch }, set: { state.queueSearch = $0 })
    }

    private func bindSelectedQueueID() -> Binding<String?> {
        Binding(
            get: { state.selectedQueue?.id },
            set: { newID in
                if let q = state.queues.first(where: { $0.id == newID }) {
                    Task { await state.selectQueue(q) }
                }
            }
        )
    }
}

struct QueueRow: View {
    let queue: BullQueue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: queue.isPaused ? "pause.circle.fill" : "tray.full")
                .foregroundStyle(queue.isPaused ? .yellow : .secondary)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(queue.name)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    CountChip(label: "wait", n: queue.counts[.waiting] ?? 0, color: .blue)
                    CountChip(label: "act", n: queue.counts[.active] ?? 0, color: .green)
                    CountChip(label: "fail", n: queue.counts[.failed] ?? 0, color: .red)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct CountChip: View {
    let label: String
    let n: Int
    let color: Color

    var body: some View {
        Text("\(label) \(n)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(n > 0 ? AnyShapeStyle(color) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
    }
}
