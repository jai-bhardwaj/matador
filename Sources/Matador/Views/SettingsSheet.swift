import SwiftUI

struct SettingsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Form {
                Section("Polling") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Queue counts every")
                            Spacer()
                            Text("\(settings.queuePollSeconds)s")
                                .font(Theme.monoSmall)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: bindInt(\.queuePollSeconds), in: 1...60, step: 1)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Job list every")
                            Spacer()
                            Text("\(settings.jobPollSeconds)s")
                                .font(Theme.monoSmall)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: bindInt(\.jobPollSeconds), in: 1...60, step: 1)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Page size")
                            Spacer()
                            Text("\(settings.pageSize)")
                                .font(Theme.monoSmall)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: bindInt(\.pageSize), in: 10...500, step: 10)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(Settings.AppearanceMode.allCases) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("About") {
                    LabeledContent("Version", value: AppConstants.version)
                    LabeledContent("Bundle id", value: AppConstants.bundleID)
                    LabeledContent("Manifest", value: AppConstants.updateManifestURL)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") {
                    state.showSettingsSheet = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 540)
    }

    private func bindInt(_ kp: ReferenceWritableKeyPath<Settings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(settings[keyPath: kp]) },
            set: { settings[keyPath: kp] = Int($0) }
        )
    }
}
