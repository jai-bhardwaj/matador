import SwiftUI

struct JobListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeSwitcher
            Divider()
            switch state.queueViewMode {
            case .jobs:
                stateTabs
                Divider()
                jobsTable
            case .schedulers:
                SchedulersView()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var modeSwitcher: some View {
        HStack {
            Picker("View", selection: bindViewMode()) {
                ForEach(QueueViewMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func bindViewMode() -> Binding<QueueViewMode> {
        Binding(
            get: { state.queueViewMode },
            set: { newMode in Task { await state.setViewMode(newMode) } }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let q = state.selectedQueue {
                Image(systemName: q.isPaused ? "pause.circle.fill" : "circle.fill")
                    .foregroundStyle(q.isPaused ? .yellow : .green)
                    .font(.caption)
                Text(q.name)
                    .font(.system(.headline, design: .default))
                Spacer()
                Button {
                    Task { await state.togglePause() }
                } label: {
                    Label(q.isPaused ? "Resume" : "Pause",
                          systemImage: q.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    Button("Clean \(state.selectedState.label) (up to 1000)") {
                        state.confirmAction = ConfirmAction(
                            title: "Clean \(state.selectedState.label)?",
                            message: "Permanently remove up to 1000 \(state.selectedState.label.lowercased()) jobs from \(q.name).",
                            destructive: true,
                            action: { Task { await state.cleanCurrentState(limit: 1000) } }
                        )
                    }
                    Button("Drain queue (waiting + delayed + prioritized)") {
                        state.confirmAction = ConfirmAction(
                            title: "Drain \(q.name)?",
                            message: "Remove every waiting, delayed, prioritized, and paused job. Active jobs are untouched.",
                            destructive: true,
                            action: { Task { await state.drainCurrentQueue() } }
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            } else {
                Text("No queue selected")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var stateTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var jobsTable: some View {
        Group {
            if state.selectedQueue == nil {
                emptyMessage("Select a queue from the sidebar")
            } else if state.jobsLoading && state.jobs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.jobs.isEmpty {
                emptyMessage("No \(state.selectedState.label.lowercased()) jobs")
            } else {
                List(selection: bindSelectedJobID()) {
                    ForEach(filteredJobs) { job in
                        JobRow(job: job).tag(job.id)
                    }
                    if state.hasMore {
                        Button("Load more…") {
                            Task { await state.loadMoreJobs() }
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .searchable(text: bindJobSearch(), prompt: "Filter jobs…")
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

    private func emptyMessage(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bindSelectedJobID() -> Binding<String?> {
        Binding(
            get: { state.selectedJobID },
            set: { id in
                if let id = id { Task { await state.selectJob(id) } }
                else { state.selectedJobID = nil; state.jobDetail = nil }
            }
        )
    }

    private func bindJobSearch() -> Binding<String> {
        Binding(get: { state.jobSearch }, set: { state.jobSearch = $0 })
    }
}

struct StateTab: View {
    let state: JobState
    let count: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(state.label)
                .font(.system(.callout))
            Text("\(count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(selected ? .white : (count > 0 ? Color.primary : Color.secondary))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(selected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct JobRow: View {
    let job: BullJobSummary

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(job.id)")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                    if let n = job.name, !n.isEmpty {
                        Text(n)
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let reason = job.failedReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if let ts = job.timestamp {
                    Text(ts.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let p = job.progress, p > 0 {
                Text("\(Int(p))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let a = job.attemptsMade, a > 1 {
                Text("×\(a)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
