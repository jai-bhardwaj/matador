import SwiftUI

struct UpdateBannerView: View {
    let checker: UpdateChecker
    @State private var showSheet = false

    var body: some View {
        if checker.available, let m = checker.latest {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.white)
                Text("Update available: v\(m.version)")
                    .foregroundStyle(.white)
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    showSheet = true
                } label: {
                    Text("Install")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor)
            .sheet(isPresented: $showSheet) {
                UpdateSheetView(checker: checker)
            }
        }
    }
}

struct UpdateSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let checker: UpdateChecker
    @State private var installer = Installer()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if checker.available, let m = checker.latest {
                notes(m)
                Divider()
                actionRow(version: m.version, url: m.url)
            } else if let err = checker.error {
                Text(err)
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
                HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("You're up to date.")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: 320)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.brandSoft)
                    .frame(width: 44, height: 44)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.brand)
            }
            VStack(alignment: .leading, spacing: 2) {
                if checker.available, let m = checker.latest {
                    Text("Matador \(m.version)")
                        .font(.title3.weight(.semibold))
                    Text("You're on v\(AppConstants.version).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Up to date")
                        .font(.title3.weight(.semibold))
                    Text("Running v\(AppConstants.version).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func notes(_ m: UpdateChecker.Manifest) -> some View {
        ScrollView {
            Text(m.notes)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 200)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: Action row — adapts to installer phase

    @ViewBuilder
    private func actionRow(version: String, url: String) -> some View {
        switch installer.phase {
        case .idle:
            HStack {
                if let dmgURL = URL(string: url) {
                    Link(destination: dmgURL) {
                        Text("Open in browser")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Later") { dismiss() }
                Button {
                    Task { await installer.install(version: version, from: url) }
                } label: {
                    Label("Download & Install", systemImage: "arrow.down.app.fill")
                        .padding(.horizontal, 4)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }

        case .downloading(let p, let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p)
                HStack {
                    Text("Downloading v\(version)…")
                        .font(.callout)
                    Spacer()
                    if total > 0 {
                        Text("\(done.prettyBytes) / \(total.prettyBytes)")
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(done.prettyBytes)
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .mounting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Verifying disk image…")
                    .font(.callout)
                Spacer()
            }

        case .staging:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(.callout)
                Spacer()
            }

        case .relaunching:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Relaunching Matador…")
                    .font(.callout.weight(.medium))
                Spacer()
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label("Install failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout.weight(.medium))
                Text(msg)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    if let dmgURL = URL(string: url) {
                        Link("Open in browser instead", destination: dmgURL)
                            .font(.callout)
                    }
                    Spacer()
                    Button("Try again") {
                        Task { await installer.install(version: version, from: url) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                Text("Log: /tmp/matador-installer.log")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
