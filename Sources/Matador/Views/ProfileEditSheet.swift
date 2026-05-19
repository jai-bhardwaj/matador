import SwiftUI

struct ProfileEditSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State var profile: RedisProfile
    @State var password: String = ""

    private var isNew: Bool { state.editingProfile == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? "New Redis Profile" : "Edit Profile")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Form {
                Section("Identity") {
                    TextField("Name", text: $profile.name)
                    TextField("BullMQ key prefix", text: $profile.bullPrefix)
                        .help("Default is \"bull\". Change only if your app uses a custom prefix.")
                }

                Section("Mode") {
                    Picker("Connection mode", selection: $profile.mode) {
                        ForEach(ConnectionMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch profile.mode {
                case .standalone:
                    Section("Connection") {
                        TextField("Host", text: $profile.host)
                        TextField("Port", value: $profile.port, format: .number.grouping(.never))
                        TextField("Database", value: $profile.database, format: .number.grouping(.never))
                        Toggle("TLS (rediss://)", isOn: $profile.tls)
                    }
                case .sentinel:
                    Section("Sentinel") {
                        TextField("Master name", text: $profile.sentinelMasterName)
                        SentinelHostsEditor(hosts: $profile.sentinelHosts)
                        TextField("Database", value: $profile.database, format: .number.grouping(.never))
                        Toggle("TLS (rediss:// for master)", isOn: $profile.tls)
                    }
                case .cluster:
                    Section("Cluster") {
                        SentinelHostsEditor(hosts: $profile.clusterSeeds, placeholder: "seed-host:6379")
                        TextField("Database", value: $profile.database, format: .number.grouping(.never))
                        Toggle("TLS (rediss://)", isOn: $profile.tls)
                    }
                }

                Section("Auth") {
                    TextField("Username (ACL)", text: $profile.username)
                        .help("Leave blank for legacy AUTH")
                    SecureField("Password", text: $password)
                        .help(isNew ? "" : "Leave blank to keep the saved password")
                    Toggle("Save password in Keychain", isOn: $profile.savePassword)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        state.editingProfile = nil
                        state.showProfileSheet = false
                        state.confirmAction = ConfirmAction(
                            title: "Delete profile?",
                            message: "Remove \(profile.name) and its saved password.",
                            destructive: true,
                            action: { state.deleteProfile(profile) }
                        )
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") {
                    state.editingProfile = nil
                    state.showProfileSheet = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isNew ? "Add & Connect" : "Save & Connect") {
                    let pw: String? = password.isEmpty ? nil : password
                    state.saveProfile(profile, password: pw)
                    state.activeProfile = profile
                    state.editingProfile = nil
                    state.showProfileSheet = false
                    dismiss()
                    state.connect()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(profile.name.isEmpty || profile.host.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 500, height: 680)
    }
}

struct SentinelHostsEditor: View {
    @Binding var hosts: [String]
    var placeholder: String = "sentinel-host:26379"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hosts.indices, id: \.self) { idx in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { hosts[idx] },
                        set: { hosts[idx] = $0 }
                    ))
                    Button {
                        hosts.remove(at: idx)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button {
                hosts.append("")
            } label: {
                Label("Add host", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct PasswordPromptSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let prompt: PasswordPrompt
    @State private var password: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password for \(prompt.profile.name)")
                .font(.headline)
            Text(prompt.profile.summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel") {
                    state.passwordPrompt = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        Task {
            await state.resumeConnect(with: password)
        }
        dismiss()
    }
}
