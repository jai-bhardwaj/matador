import SwiftUI

struct JobDetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.selectedJobID == nil {
                placeholder
            } else if state.jobDetailLoading && state.jobDetail == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = state.jobDetail {
                detail(d)
            } else {
                placeholder
            }
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Select a job")
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Pick a job from the list to see its data, options, and trace.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ d: BullJobDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(d)
                actions(d)
                metaGrid(d)

                if let reason = d.failedReason, !reason.isEmpty {
                    section("Failed reason", accent: Theme.failed) {
                        Text(reason)
                            .font(Theme.mono)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.red.opacity(0.15), lineWidth: 1)
                            )
                    }
                }

                flowSection(d)

                section("Data") {
                    JSONBlock(text: d.data)
                }
                section("Options") {
                    JSONBlock(text: d.opts)
                }
                if !d.returnvalue.isEmpty {
                    section("Return value", accent: Theme.active) {
                        JSONBlock(text: d.returnvalue)
                    }
                }
                if !d.stacktrace.isEmpty {
                    section("Stack trace", count: d.stacktrace.count, accent: Theme.failed) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(d.stacktrace.enumerated()), id: \.offset) { idx, frame in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(idx)")
                                        .font(Theme.monoTiny.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 24, alignment: .trailing)
                                    Text(frame)
                                        .font(Theme.monoSmall)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .codeBlock()
                    }
                }
                if !d.logs.isEmpty {
                    section("Logs", count: d.logs.count) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(d.logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(Theme.monoSmall)
                                    .textSelection(.enabled)
                            }
                        }
                        .codeBlock()
                    }
                }
            }
            .padding(24)
        }
    }

    private func header(_ d: BullJobDetail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(state.selectedState.accent.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: state.selectedState.systemIcon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(state.selectedState.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(d.name)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("#\(d.id)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Text(d.queueKey)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await state.loadJobDetail() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
    }

    @ViewBuilder
    private func actions(_ d: BullJobDetail) -> some View {
        HStack(spacing: 8) {
            if state.selectedState == .failed {
                Button {
                    Task { await state.retrySelectedJob() }
                } label: { Label("Retry", systemImage: "arrow.clockwise.circle") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            if state.selectedState == .delayed {
                Button {
                    Task { await state.promoteSelectedJob() }
                } label: { Label("Promote", systemImage: "arrow.up.circle") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            Spacer()
            Button(role: .destructive) {
                state.confirmAction = ConfirmAction(
                    title: "Remove job?",
                    message: "Permanently remove #\(d.id) from \(d.queueKey).",
                    destructive: true,
                    action: { Task { await state.removeSelectedJob() } }
                )
            } label: { Label("Remove", systemImage: "trash") }
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }

    private func metaGrid(_ d: BullJobDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                metaCell("Attempts", "\(d.attemptsMade)", icon: "arrow.clockwise")
                Divider().frame(height: 32)
                metaCell("Delay", d.delay > 0 ? "\(d.delay)ms" : "—", icon: "clock")
                if let p = d.priority {
                    Divider().frame(height: 32)
                    metaCell("Priority", "\(p)", icon: "arrow.up.right")
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                metaCell("Created", d.timestamp?.formatted(.relative(presentation: .named)) ?? "—", icon: "calendar")
                Divider().frame(height: 32)
                metaCell("Started", d.processedOn?.formatted(.relative(presentation: .named)) ?? "—", icon: "play")
                Divider().frame(height: 32)
                metaCell("Finished", d.finishedOn?.formatted(.relative(presentation: .named)) ?? "—", icon: "flag.checkered")
            }
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func metaCell(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(label)
                    .font(Theme.sectionLabel)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(Theme.mono)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        count: Int? = nil,
        accent: Color = Theme.brand,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(accent.opacity(0.7))
                    .frame(width: 3, height: 12)
                    .clipShape(Capsule())
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                if let c = count {
                    Text("\(c)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 0)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }
            }
            content()
        }
    }

    @ViewBuilder
    private func flowSection(_ d: BullJobDetail) -> some View {
        let unresolved = state.jobChildren.unresolved
        let resolved = state.jobChildren.resolved
        let hasParent = d.parent != nil
        if hasParent || !unresolved.isEmpty || !resolved.isEmpty {
            section("Flow") {
                VStack(spacing: 6) {
                    if let parent = d.parent {
                        FlowRow(label: "Parent", value: parent, icon: "arrow.up.circle.fill", color: .blue) {
                            jumpTo(parentRef: parent)
                        }
                    }
                    ForEach(unresolved, id: \.self) { ref in
                        FlowRow(label: "Waiting child", value: ref, icon: "hourglass", color: .orange) {
                            jumpTo(parentRef: ref)
                        }
                    }
                    ForEach(resolved, id: \.self) { ref in
                        FlowRow(label: "Resolved child", value: ref, icon: "checkmark.circle.fill", color: .green) {
                            jumpTo(parentRef: ref)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    private func jumpTo(parentRef ref: String) {
        let parts = ref.split(separator: ":")
        guard parts.count >= 3, let lastID = parts.last else { return }
        let id = String(lastID)
        let qname = parts.dropFirst().dropLast().joined(separator: ":")
        if let q = state.queues.first(where: { $0.name == qname }) {
            Task {
                await state.selectQueue(q)
                await state.selectJob(id)
            }
        } else {
            Task { await state.selectJob(id) }
        }
    }
}

struct FlowRow: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.16))
                        .frame(width: 22, height: 22)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(Theme.sectionLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(value)
                    .font(Theme.monoSmall)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption2)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct JSONBlock: View {
    let text: String

    var body: some View {
        Text(pretty)
            .codeBlock()
    }

    private var pretty: String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: out, encoding: .utf8)
        else { return text.isEmpty ? "—" : text }
        return s
    }
}
