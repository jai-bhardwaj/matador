import SwiftUI
import Charts

struct MetricsView: View {
    @Environment(AppState.self) private var state

    private var queueID: String? { state.selectedQueue?.id }

    private var samples: [QueueSample] {
        guard let id = queueID else { return [] }
        return MetricsStore.shared.samples(for: id)
    }

    private var rates: [QueueRate] {
        guard let id = queueID else { return [] }
        return MetricsStore.shared.rates(for: id)
    }

    var body: some View {
        Group {
            if samples.count < 2 {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        currentStatsCard
                        stateOverTimeCard
                        throughputCard
                        stalledWorkersCard
                    }
                    .padding(20)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Gathering data…")
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Charts populate as new samples arrive (every 5s).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Current stats

    private var currentStatsCard: some View {
        let latest = samples.last
        // Adaptive grid: tiles flow into 2-4 columns depending on width.
        let columns = [GridItem(.adaptive(minimum: 130), spacing: 10, alignment: .top)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(JobState.allCases) { s in
                StatTile(
                    label: s.label,
                    value: latest?.count(s) ?? 0,
                    color: s.accent,
                    icon: s.systemIcon
                )
            }
        }
    }

    // MARK: State counts over time

    private var stateOverTimeCard: some View {
        sectionCard("Queue counts (last \(samples.count * 5)s)") {
            Chart {
                ForEach(JobState.allCases) { s in
                    ForEach(samples) { sample in
                        AreaMark(
                            x: .value("t", sample.timestamp),
                            y: .value("count", sample.count(s)),
                            stacking: .standard
                        )
                        .foregroundStyle(by: .value("State", s.label))
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartForegroundStyleScale(stateColorMap())
            .chartLegend(position: .top, alignment: .leading, spacing: 8)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 220)
        }
    }

    // MARK: Throughput (completed / failed per second)

    private var throughputCard: some View {
        sectionCard("Throughput (per second)") {
            Chart(rates) { r in
                LineMark(
                    x: .value("t", r.timestamp),
                    y: .value("completed/s", r.completedDelta)
                )
                .foregroundStyle(Theme.active)
                .interpolationMethod(.catmullRom)
                .symbol(Circle().strokeBorder(lineWidth: 1.2))
                .symbolSize(20)

                LineMark(
                    x: .value("t", r.timestamp),
                    y: .value("failed/s", r.failedDelta)
                )
                .foregroundStyle(Theme.failed)
                .interpolationMethod(.catmullRom)
                .symbol(Circle().strokeBorder(lineWidth: 1.2))
                .symbolSize(20)
            }
            .chartForegroundStyleScale([
                "completed/s": Theme.active,
                "failed/s": Theme.failed,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
    }

    // MARK: Stalled + workers

    private var stalledWorkersCard: some View {
        sectionCard("Stalled jobs · Workers") {
            Chart(samples) { s in
                BarMark(
                    x: .value("t", s.timestamp),
                    y: .value("stalled", s.stalled)
                )
                .foregroundStyle(Theme.delayed)

                LineMark(
                    x: .value("t", s.timestamp),
                    y: .value("workers", s.workers)
                )
                .foregroundStyle(Theme.waiting)
                .interpolationMethod(.stepCenter)
            }
            .chartForegroundStyleScale([
                "stalled": Theme.delayed,
                "workers": Theme.waiting,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 140)
        }
    }

    // MARK: Helpers

    private func stateColorMap() -> KeyValuePairs<String, Color> {
        [
            JobState.waiting.label: JobState.waiting.accent,
            JobState.active.label: JobState.active.accent,
            JobState.delayed.label: JobState.delayed.accent,
            JobState.prioritized.label: JobState.prioritized.accent,
            JobState.paused.label: JobState.paused.accent,
            JobState.failed.label: JobState.failed.accent,
            JobState.completed.label: JobState.completed.accent,
            JobState.waitingChildren.label: JobState.waitingChildren.accent,
        ]
    }

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Theme.brand.opacity(0.7))
                    .frame(width: 3, height: 12)
                    .clipShape(Capsule())
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let label: String
    let value: Int
    let color: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(label.uppercased())
                    .font(.caption2.weight(.medium))
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
            }
            Text("\(value)")
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(value > 0 ? color : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.20), lineWidth: 1)
        )
    }
}

// MARK: - Sparkline (small inline chart for queue header)

struct ThroughputSparkline: View {
    let rates: [QueueRate]
    var height: CGFloat = 28

    var body: some View {
        Chart(rates) { r in
            AreaMark(
                x: .value("t", r.timestamp),
                y: .value("c", r.completedDelta)
            )
            .foregroundStyle(LinearGradient(
                colors: [Theme.active.opacity(0.45), Theme.active.opacity(0.05)],
                startPoint: .top, endPoint: .bottom
            ))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.background(Color.clear) }
        .frame(height: height)
        .frame(maxWidth: 120)
    }
}
