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
        .background(Color(NSColor.textBackgroundColor))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Select a job").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ d: BullJobDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(d)
                Divider()
                actions(d)
                Divider()
                metaGrid(d)

                if let reason = d.failedReason, !reason.isEmpty {
                    section("Failed Reason") {
                        Text(reason)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
                    section("Return Value") {
                        JSONBlock(text: d.returnvalue)
                    }
                }
                if !d.stacktrace.isEmpty {
                    section("Stack Trace (\(d.stacktrace.count))") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(d.stacktrace.enumerated()), id: \.offset) { idx, frame in
                                Text("[\(idx)] \(frame)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if !d.logs.isEmpty {
                    section("Logs (\(d.logs.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(d.logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(20)
        }
    }

    private func header(_ d: BullJobDetail) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("#\(d.id) — \(d.name)")
                    .font(.title3.weight(.semibold))
                Text(d.queueKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await state.loadJobDetail() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func actions(_ d: BullJobDetail) -> some View {
        HStack(spacing: 8) {
            if state.selectedState == .failed {
                Button {
                    Task { await state.retrySelectedJob() }
                } label: { Label("Retry", systemImage: "arrow.clockwise.circle") }
                    .buttonStyle(.bordered)
            }
            if state.selectedState == .delayed {
                Button {
                    Task { await state.promoteSelectedJob() }
                } label: { Label("Promote", systemImage: "arrow.up.circle") }
                    .buttonStyle(.bordered)
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
        }
    }

    private func metaGrid(_ d: BullJobDetail) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            row("Attempts", "\(d.attemptsMade)")
            row("Delay", "\(d.delay)ms")
            if let p = d.priority { row("Priority", "\(p)") }
            row("Created", d.timestamp?.formatted(date: .abbreviated, time: .standard) ?? "—")
            row("Started", d.processedOn?.formatted(date: .abbreviated, time: .standard) ?? "—")
            row("Finished", d.finishedOn?.formatted(date: .abbreviated, time: .standard) ?? "—")
            if let parent = d.parent { row("Parent", parent) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 6) {
                    if let parent = d.parent {
                        FlowRow(label: "Parent", value: parent, icon: "arrow.up.circle.fill", color: .blue) {
                            jumpTo(parentRef: parent)
                        }
                    }
                    ForEach(unresolved, id: \.self) { ref in
                        FlowRow(label: "Waiting child", value: ref, icon: "circle", color: .orange) {
                            jumpTo(parentRef: ref)
                        }
                    }
                    ForEach(resolved, id: \.self) { ref in
                        FlowRow(label: "Resolved child", value: ref, icon: "checkmark.circle.fill", color: .green) {
                            jumpTo(parentRef: ref)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Parent/child refs look like "bull:emails:42". Switch the active queue
    /// (if it's in our discovered list) and select the job id.
    private func jumpTo(parentRef ref: String) {
        // ref format: "<prefix>:<queueName>:<id>"
        let parts = ref.split(separator: ":")
        guard parts.count >= 3, let lastID = parts.last else { return }
        let id = String(lastID)
        // Find queue: prefix is first segment, queueName is everything in between
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
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(label)
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.tertiary)
                    .font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct JSONBlock: View {
    let text: String

    var body: some View {
        Text(pretty)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var pretty: String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: out, encoding: .utf8)
        else { return text.isEmpty ? "(empty)" : text }
        return s
    }
}
