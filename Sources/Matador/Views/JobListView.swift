import SwiftUI

struct JobListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            stalledBanner
            Divider().opacity(0.5)
            modeSwitcher
            Divider().opacity(0.5)
            switch state.queueViewMode {
            case .jobs:
                stateTabs
                bulkSelectionBar
                Divider().opacity(0.4)
                jobsTable
            case .schedulers:
                SchedulersView()
            case .workers:
                WorkersView()
            case .metrics:
                MetricsView()
            }
        }
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var stalledBanner: some View {
        if let q = state.selectedQueue, q.stalledCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.delayed)
                Text("\(q.stalledCount) job\(q.stalledCount == 1 ? "" : "s") may be stalled")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("workers haven't extended the lock — they may be wedged or dead")
                    .font(Theme.monoTiny)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.delayed.opacity(0.12))
            .overlay(Rectangle().fill(Theme.delayed).frame(height: 1), alignment: .top)
            .overlay(Rectangle().fill(Theme.delayed.opacity(0.4)).frame(height: 1), alignment: .bottom)
        }
    }

    @ViewBuilder
    private var bulkSelectionBar: some View {
        if !state.selectedJobIDs.isEmpty {
            HStack(spacing: 8) {
                Text("\(state.selectedJobIDs.count) selected")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.brand)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if state.selectedState == .failed {
                    Button {
                        state.confirmAction = ConfirmAction(
                            title: "Retry \(state.selectedJobIDs.count) jobs?",
                            message: "Move every selected failed job back to wait.",
                            destructive: false,
                            action: { Task { await state.bulkRetry() } }
                        )
                    } label: { Label("Retry all", systemImage: "arrow.clockwise.circle") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if state.selectedState == .delayed {
                    Button {
                        Task { await state.bulkPromote() }
                    } label: { Label("Promote all", systemImage: "arrow.up.circle") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button(role: .destructive) {
                    state.confirmAction = ConfirmAction(
                        title: "Remove \(state.selectedJobIDs.count) jobs?",
                        message: "Permanently remove every selected job.",
                        destructive: true,
                        action: { Task { await state.bulkRemove() } }
                    )
                } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Clear") { state.clearJobSelection() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.brand.opacity(0.06))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let q = state.selectedQueue {
                ZStack {
                    Circle()
                        .fill(q.isPaused ? Color.yellow.opacity(0.18) : Color.green.opacity(0.18))
                        .frame(width: 22, height: 22)
                    Image(systemName: q.isPaused ? "pause.fill" : "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(q.isPaused ? .yellow : .green)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.name)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if q.isPaused {
                        Text("paused")
                            .font(Theme.monoTiny)
                            .foregroundStyle(.yellow)
                    }
                }
                .layoutPriority(0)
                Spacer(minLength: 8)
                Button {
                    Task { await state.togglePause() }
                } label: {
                    Label(q.isPaused ? "Resume" : "Pause",
                          systemImage: q.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Menu {
                    Button("Clean current state (up to 1000)") {
                        state.confirmAction = ConfirmAction(
                            title: "Clean \(state.selectedState.label)?",
                            message: "Permanently remove up to 1000 \(state.selectedState.label.lowercased()) jobs from \(q.name).",
                            destructive: true,
                            action: { Task { await state.cleanCurrentState(limit: 1000) } }
                        )
                    }
                    Button("Drain queue (waiting + delayed + prioritized + paused)") {
                        state.confirmAction = ConfirmAction(
                            title: "Drain \(q.name)?",
                            message: "Remove every waiting, delayed, prioritized, and paused job. Active jobs are untouched.",
                            destructive: true,
                            action: { Task { await state.drainCurrentQueue() } }
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
            } else {
                Text("Select a queue")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Mode switcher

    private var modeSwitcher: some View {
        // ViewThatFits picks the first layout that doesn't truncate. At wide
        // widths we get pills with full labels + an inline sparkline; at
        // narrow widths we collapse to icon-only pills.
        ViewThatFits(in: .horizontal) {
            wideSwitcher
            mediumSwitcher
            compactSwitcher
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var wideSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(QueueViewMode.allCases) { m in modePill(m, compact: false) }
            Spacer(minLength: 8)
            sparkline
        }
    }

    private var mediumSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(QueueViewMode.allCases) { m in modePill(m, compact: false) }
            Spacer(minLength: 0)
        }
    }

    private var compactSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(QueueViewMode.allCases) { m in modePill(m, compact: true) }
            Spacer(minLength: 0)
        }
    }

    private func modePill(_ m: QueueViewMode, compact: Bool) -> some View {
        Button {
            Task { await state.setViewMode(m) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: m.icon)
                    .font(.caption2)
                if !compact {
                    Text(m.label)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, 6)
            .background(
                state.queueViewMode == m ? Theme.brandSoft : Color.clear,
                in: Capsule()
            )
            .foregroundStyle(state.queueViewMode == m ? Theme.brand : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(m.label)
    }

    @ViewBuilder
    private var sparkline: some View {
        if let qID = state.selectedQueue?.id {
            let rates = MetricsStore.shared.rates(for: qID)
            if rates.count > 1 {
                HStack(spacing: 6) {
                    Text("throughput")
                        .font(Theme.monoTiny)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    ThroughputSparkline(rates: rates)
                }
            }
        }
    }

    // MARK: State tabs

    private var stateTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(JobState.allCases) { s in
                    StateTab(
                        state: s,
                        count: state.selectedQueue?.counts[s] ?? 0,
                        selected: state.selectedState == s
                    )
                    .onTapGesture {
                        Task { await state.setState(s) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: Jobs table

    private var jobsTable: some View {
        Group {
            if state.selectedQueue == nil {
                emptyMessage(icon: "tray", title: "Pick a queue", subtitle: "Select one from the sidebar")
            } else if state.jobsLoading && state.jobs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.jobs.isEmpty {
                emptyMessage(
                    icon: state.selectedState.systemIcon,
                    title: "No \(state.selectedState.label.lowercased()) jobs",
                    subtitle: nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredJobs) { job in
                            JobRow(
                                job: job,
                                selected: state.selectedJobID == job.id,
                                bulkSelected: state.selectedJobIDs.contains(job.id),
                                showBulkCheckbox: !state.selectedJobIDs.isEmpty
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await state.selectJob(job.id) }
                            }
                            .simultaneousGesture(
                                TapGesture().modifiers(.command).onEnded {
                                    state.toggleJobSelection(job.id)
                                }
                            )
                            .simultaneousGesture(
                                TapGesture().modifiers(.shift).onEnded {
                                    state.toggleJobSelection(job.id)
                                }
                            )
                        }
                        if state.hasMore {
                            Button {
                                Task { await state.loadMoreJobs() }
                            } label: {
                                Text("Load more")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .searchable(text: bindJobSearch(), prompt: "Filter jobs by id, name, or error")
            }
        }
    }

    private var filteredJobs: [BullJobSummary] {
        let s = state.jobSearch.lowercased()
        if s.isEmpty { return state.jobs }
        return state.jobs.filter {
            $0.id.lowercased().contains(s) ||
            ($0.name?.lowercased().contains(s) ?? false) ||
            ($0.failedReason?.lowercased().contains(s) ?? false)
        }
    }

    private func emptyMessage(icon: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.secondary)
            if let s = subtitle {
                Text(s)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bindJobSearch() -> Binding<String> {
        Binding(get: { state.jobSearch }, set: { state.jobSearch = $0 })
    }
}

// MARK: - State tab pill

struct StateTab: View {
    let state: JobState
    let count: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.systemIcon)
                .font(.caption2)
                .foregroundStyle(selected ? state.accent : (count > 0 ? Color.primary.opacity(0.7) : Color.secondary))
            Text(state.label)
                .font(.system(.callout, design: .rounded).weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if count > 0 {
                Text("\(count)")
                    .font(.system(.caption, design: .monospaced).monospacedDigit())
                    .foregroundStyle(selected ? state.accent : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 0)
                    .background(
                        (selected ? state.accent.opacity(0.18) : Color.secondary.opacity(0.12)),
                        in: Capsule()
                    )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? state.accent : .primary)
        .background(
            selected ? state.accent.opacity(0.12) : Color.clear,
            in: Capsule()
        )
        .overlay(
            Capsule()
                .stroke(selected ? state.accent.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Job row

struct JobRow: View {
    let job: BullJobSummary
    let selected: Bool
    var bulkSelected: Bool = false
    var showBulkCheckbox: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if showBulkCheckbox {
                Image(systemName: bulkSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(bulkSelected ? Theme.brand : .secondary)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("#\(job.id)")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                    if let n = job.name, !n.isEmpty {
                        Text(n)
                            .font(.system(.callout, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let reason = job.failedReason, !reason.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                } else if let ts = job.timestamp {
                    Text(ts.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let p = job.progress, p > 0 {
                ProgressBadge(percent: Int(p))
            }
            if let a = job.attemptsMade, a > 1 {
                AttemptsBadge(n: a)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            (bulkSelected ? Theme.brand.opacity(0.12) :
             selected ? Theme.brandSoft : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    (bulkSelected ? Theme.brand.opacity(0.45) :
                     selected ? Theme.brand.opacity(0.3) : Color.clear),
                    lineWidth: 1
                )
        )
    }
}

private struct ProgressBadge: View {
    let percent: Int
    var body: some View {
        Text("\(percent)%")
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(Theme.active)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.active.opacity(0.14), in: Capsule())
    }
}

private struct AttemptsBadge: View {
    let n: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9))
            Text("\(n)")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.orange.opacity(0.14), in: Capsule())
    }
}
