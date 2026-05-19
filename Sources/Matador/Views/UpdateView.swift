import SwiftUI

struct UpdateBannerView: View {
    let checker: UpdateChecker

    var body: some View {
        if checker.available, let m = checker.latest {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.white)
                Text("Update available: \(m.version)")
                    .foregroundStyle(.white)
                    .font(.callout.weight(.medium))
                Spacer()
                if let url = URL(string: m.url) {
                    Link("Download", destination: url)
                        .foregroundStyle(.white)
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor)
        }
    }
}

struct UpdateSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let checker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if checker.available, let m = checker.latest {
                Text("Matador \(m.version) is available")
                    .font(.title3.weight(.semibold))
                Text("You're on v\(AppConstants.version).")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(m.notes)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                HStack {
                    Spacer()
                    Button("Later") { dismiss() }
                    if let url = URL(string: m.url) {
                        Link("Download", destination: url)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if let err = checker.error {
                Text("Couldn't check for updates")
                    .font(.headline)
                Text(err)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }
                }
            } else {
                Text("You're up to date")
                    .font(.headline)
                Text("Running v\(AppConstants.version).")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
