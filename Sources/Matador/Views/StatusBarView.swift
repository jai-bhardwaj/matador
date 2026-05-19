import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 14) {
            connectionPill
            Spacer()
            if let q = state.selectedQueue, state.connectionState == .connected {
                queueStats(q)
            }
            Spacer()
            Text("v\(AppConstants.version)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .overlay(Divider().opacity(0.5), alignment: .top)
    }

    private var connectionPill: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(dotColor.opacity(0.25))
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            switch state.connectionState {
            case .connected:
                if let p = state.activeProfile {
                    Text(p.summary)
                        .font(Theme.monoTiny)
                        .foregroundStyle(.secondary)
                }
            case .connecting:
                Text("connecting…")
                    .font(Theme.monoTiny)
                    .foregroundStyle(.secondary)
            case .reconnecting(let s, let attempt):
                Text("reconnecting in \(s)s (attempt \(attempt))")
                    .font(Theme.monoTiny)
                    .foregroundStyle(.yellow)
                Button("Retry now") { Task { await state.connect() } }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            case .disconnected(let msg):
                Text(msg ?? "disconnected")
                    .font(Theme.monoTiny)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Button("Retry") { Task { await state.connect() } }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
        }
    }

    private var dotColor: Color {
        switch state.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    private func queueStats(_ q: BullQueue) -> some View {
        HStack(spacing: 12) {
            ForEach([JobState.waiting, .active, .failed], id: \.self) { s in
                HStack(spacing: 5) {
                    Circle().fill(s.accent).frame(width: 5, height: 5)
                    Text(s.label.lowercased())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(q.counts[s] ?? 0)")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle((q.counts[s] ?? 0) > 0
                            ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                            : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                }
            }
        }
    }
}
