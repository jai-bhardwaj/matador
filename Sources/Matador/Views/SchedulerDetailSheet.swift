import SwiftUI

struct SchedulerDetailSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let scheduler: BullScheduler

    private var tz: TimeZone {
        if let s = scheduler.tz, let z = TimeZone(identifier: s) { return z }
        return .current
    }

    private var nextFires: [Date] {
        if let pattern = scheduler.pattern, let cron = CronExpression(pattern) {
            return cron.nextFires(after: Date(), in: tz, count: 5)
        }
        if let every = scheduler.every {
            // For simple interval schedulers, project from the next-run time.
            let start = scheduler.nextRun ?? Date()
            return (0..<5).map { i in start.addingTimeInterval(TimeInterval(every) * Double(i) / 1000.0) }
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scheduler.name ?? "(unnamed scheduler)")
                        .font(.title3.weight(.semibold))
                    Text("#\(scheduler.id)")
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    grid

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Next 5 fires")
                            .font(.caption.weight(.semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        if nextFires.isEmpty {
                            Text("Couldn't project next runs — unsupported cadence or invalid cron pattern.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(Array(nextFires.enumerated()), id: \.offset) { idx, date in
                                HStack(spacing: 10) {
                                    Text("#\(idx + 1)")
                                        .font(Theme.monoTiny.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 28, alignment: .leading)
                                    Text(date.formatted(date: .abbreviated, time: .standard))
                                        .font(Theme.monoSmall)
                                    Spacer()
                                    Text(date.formatted(.relative(presentation: .named)))
                                        .font(Theme.monoTiny)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .cardStyle()

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            state.confirmAction = ConfirmAction(
                                title: "Remove scheduler?",
                                message: "Remove \(scheduler.name ?? scheduler.id). Already-emitted jobs are not affected.",
                                destructive: true,
                                action: {
                                    Task {
                                        await state.removeScheduler(id: scheduler.id)
                                        await MainActor.run { state.schedulerDetail = nil }
                                    }
                                }
                            )
                        } label: { Label("Remove", systemImage: "trash") }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 540)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Cadence", scheduler.cadence)
            if let tz = scheduler.tz, !tz.isEmpty { row("Timezone", tz) }
            if let lim = scheduler.limit { row("Limit", "\(lim)") }
            if let end = scheduler.endDate {
                row("End date", end.formatted(date: .abbreviated, time: .standard))
            }
            if let next = scheduler.nextRun {
                row("Next run", "\(next.formatted(date: .abbreviated, time: .standard)) (\(next.formatted(.relative(presentation: .named))))")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label.uppercased())
                .font(.caption.weight(.medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(Theme.monoSmall)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
