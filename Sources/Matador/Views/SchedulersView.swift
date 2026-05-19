import SwiftUI

struct SchedulersView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.schedulersLoading && state.schedulers.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.schedulers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No schedulers")
                        .foregroundStyle(.secondary)
                    Text("Repeatable jobs registered via `queue.upsertJobScheduler(...)` show up here.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: bindSelectedSchedulerID()) {
                    ForEach(state.schedulers) { s in
                        SchedulerRow(scheduler: s)
                            .tag(s.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { state.schedulerDetail = s }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    state.confirmAction = ConfirmAction(
                                        title: "Remove scheduler?",
                                        message: "Remove repeatable scheduler \(s.id). Already-emitted jobs are not affected.",
                                        destructive: true,
                                        action: { Task { await state.removeScheduler(id: s.id) } }
                                    )
                                } label: { Label("Remove", systemImage: "trash") }
                                Button {
                                    state.schedulerDetail = s
                                } label: { Label("Details", systemImage: "info.circle") }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .toolbar {
            Button {
                Task { await state.refreshSchedulers() }
            } label: { Image(systemName: "arrow.clockwise") }
        }
    }

    private func bindSelectedSchedulerID() -> Binding<String?> {
        Binding(
            get: { state.selectedSchedulerID },
            set: { state.selectedSchedulerID = $0 }
        )
    }
}

struct SchedulerRow: View {
    let scheduler: BullScheduler

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.purple)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(scheduler.name ?? "(unnamed)")
                        .font(.system(.callout).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("#\(scheduler.id)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Text(scheduler.cadence)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let tz = scheduler.tz, !tz.isEmpty {
                        Text(tz)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let nextRun = scheduler.nextRun {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("next")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(nextRun.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
