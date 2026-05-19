import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            profileHeader
            Divider().opacity(0.5)
            queueList
        }
        .background(.regularMaterial)
    }

    // MARK: Profile header

    private var profileHeader: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Profiles") {
                    ForEach(state.profiles) { p in
                        Button {
                            Task { state.selectProfile(p) }
                        } label: {
                            HStack {
                                Text(p.name)
                                if state.activeProfile?.id == p.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    state.editingProfile = nil
                    state.showProfileSheet = true
                } label: { Label("New profile…", systemImage: "plus") }
                if let active = state.activeProfile {
                    Button {
                        state.editingProfile = active
                        state.showProfileSheet = true
                    } label: { Label("Edit \(active.name)…", systemImage: "pencil") }
                    Button(role: .destructive) {
                        state.confirmAction = ConfirmAction(
                            title: "Delete profile?",
                            message: "Remove \(active.name) (\(active.summary)) and its saved password.",
                            destructive: true,
                            action: { state.deleteProfile(active) }
                        )
                    } label: { Label("Delete \(active.name)", systemImage: "trash") }
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(connectionDotColor.opacity(0.18))
                            .frame(width: 26, height: 26)
                        Circle()
                            .fill(connectionDotColor)
                            .frame(width: 9, height: 9)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.activeProfile?.name ?? "No profile")
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                        Text(state.activeProfile?.summary ?? "")
                            .font(Theme.monoTiny)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
                    .font(Theme.sectionLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.queues.isEmpty {
                    Text("\(state.queues.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
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
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            TextField("Filter…", text: bindQueueSearch())
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            if state.queues.isEmpty {
                queueEmptyState
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredQueues) { q in
                            QueueRow(queue: q, selected: state.selectedQueue?.id == q.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task { await state.selectQueue(q) }
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var queueEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No queues found")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("BullMQ stores queues under \(state.activeProfile?.bullPrefix ?? "bull"):*:meta")
                .font(Theme.monoTiny)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var filteredQueues: [BullQueue] {
        let s = state.queueSearch.lowercased()
        if s.isEmpty { return state.queues }
        return state.queues.filter { $0.name.lowercased().contains(s) }
    }

    private func bindQueueSearch() -> Binding<String> {
        Binding(get: { state.queueSearch }, set: { state.queueSearch = $0 })
    }
}

struct QueueRow: View {
    let queue: BullQueue
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(queue.isPaused ? Color.yellow.opacity(0.18) : Theme.brandSoft)
                    .frame(width: 28, height: 28)
                Image(systemName: queue.isPaused ? "pause.fill" : "tray.full.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(queue.isPaused ? .yellow : Theme.brand)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(queue.name)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    QueueChip(state: .waiting, n: queue.counts[.waiting] ?? 0)
                    QueueChip(state: .active, n: queue.counts[.active] ?? 0)
                    QueueChip(state: .failed, n: queue.counts[.failed] ?? 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Theme.brandSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Theme.brand.opacity(0.25) : Color.clear, lineWidth: 1)
        )
    }
}

struct QueueChip: View {
    let state: JobState
    let n: Int

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(n > 0 ? state.accent : Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)
            Text("\(n)")
                .font(.system(.caption2, design: .monospaced).monospacedDigit())
                .foregroundStyle(n > 0
                    ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                    : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            (n > 0 ? state.accent.opacity(0.12) : Color.secondary.opacity(0.08)),
            in: Capsule()
        )
    }
}
