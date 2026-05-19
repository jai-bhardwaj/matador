import SwiftUI

struct WorkersView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.workersLoading && state.workers.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.workers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No workers connected")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("Workers are discovered via Redis CLIENT LIST. They register with names like \(state.activeProfile?.bullPrefix ?? "bull"):<queue>:worker.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(state.workers) { w in
                            WorkerRow(worker: w)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .toolbar {
            Button {
                Task { await state.refreshWorkers() }
            } label: { Image(systemName: "arrow.clockwise") }
        }
    }
}

struct WorkerRow: View {
    let worker: BullWorker

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(worker.idleSeconds < 30 ? Color.green.opacity(0.18) : Color.secondary.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: worker.idleSeconds < 30 ? "bolt.fill" : "moon.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(worker.idleSeconds < 30 ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(worker.displayName)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    Label("id \(worker.id)", systemImage: "number")
                        .font(Theme.monoTiny)
                        .foregroundStyle(.tertiary)
                    Label(worker.addr, systemImage: "network")
                        .font(Theme.monoTiny)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("idle \(worker.idleSeconds)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(worker.idleSeconds < 30 ? .green : .secondary)
                Text("up \(formatDuration(worker.age))")
                    .font(Theme.monoTiny)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 86400)d \((seconds % 86400) / 3600)h"
    }
}
