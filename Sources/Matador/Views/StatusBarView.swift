import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            connectionPill
            Spacer()
            if let q = state.selectedQueue {
                queueStats(q)
            }
            Spacer()
            Text("v\(AppConstants.version)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    private var connectionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            switch state.connectionState {
            case .connected:
                if let p = state.activeProfile {
                    Text(p.summary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            case .connecting:
                Text("connecting…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .disconnected(let msg):
                Text(msg ?? "disconnected")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            if case .disconnected = state.connectionState {
                Button("Reconnect") { Task { await state.connect() } }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
        }
    }

    private var dotColor: Color {
        switch state.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        }
    }

    private func queueStats(_ q: BullQueue) -> some View {
        HStack(spacing: 14) {
            ForEach(JobState.allCases) { s in
                let n = q.counts[s] ?? 0
                if n > 0 || s == .waiting || s == .active || s == .failed {
                    HStack(spacing: 4) {
                        Text(s.label.lowercased())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(n)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(n > 0 ? .primary : .tertiary)
                    }
                }
            }
        }
    }
}
