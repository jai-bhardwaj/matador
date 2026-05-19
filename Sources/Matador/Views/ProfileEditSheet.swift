import SwiftUI

struct ProfileEditSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State var profile: RedisProfile
    @State var password: String = ""
    @State private var pasteURL: String = ""
    @State private var urlError: String?
    @State private var testResult: TestResult?

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
                Section("Quick start") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("redis://user:pass@host:port/db", text: $pasteURL)
                                .textFieldStyle(.roundedBorder)
                            Button("Parse") { parseURL() }
                                .disabled(pasteURL.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let err = urlError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text("Paste a Redis URL to auto-fill host / port / user / pass / db / TLS.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

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
                        tlsPicker
                    }
                case .sentinel:
                    Section("Sentinel") {
                        TextField("Master name", text: $profile.sentinelMasterName)
                        SentinelHostsEditor(hosts: $profile.sentinelHosts)
                        TextField("Database", value: $profile.database, format: .number.grouping(.never))
                        tlsPicker
                    }
                case .cluster:
                    Section("Cluster") {
                        SentinelHostsEditor(hosts: $profile.clusterSeeds, placeholder: "seed-host:6379")
                        TextField("Database", value: $profile.database, format: .number.grouping(.never))
                        tlsPicker
                    }
                }

                Section("Auth") {
                    TextField("Username (ACL)", text: $profile.username)
                        .help("Leave blank for legacy AUTH")
                    SecureField("Password", text: $password)
                        .help(isNew ? "" : "Leave blank to keep the saved password")
                    Toggle("Save password in Keychain", isOn: $profile.savePassword)
                }

                Section("Diagnostics") {
                    HStack(spacing: 10) {
                        Button {
                            runTest()
                        } label: {
                            Label(testResult == .testing ? "Testing…" : "Test Connection",
                                  systemImage: "stethoscope")
                        }
                        .disabled(testResult == .testing || profile.name.isEmpty || (profile.mode == .standalone && profile.host.isEmpty))
                        if case .testing = testResult {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                    }
                    if let r = testResult, r != .testing {
                        testResultView(r)
                    }
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
                .disabled(profile.name.isEmpty || (profile.mode == .standalone && profile.host.isEmpty))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 760)
    }

    // MARK: TLS picker

    private var tlsPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("TLS")
                Spacer()
                Picker("", selection: $profile.tlsMode) {
                    ForEach(TLSMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            Text(profile.tlsMode.help)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: URL paste

    private func parseURL() {
        guard let parts = RedisURL.parse(pasteURL) else {
            urlError = "Could not parse — expected redis://... or rediss://..."
            return
        }
        urlError = nil
        profile.mode = .standalone
        profile.host = parts.host
        profile.port = parts.port
        profile.username = parts.username
        if !parts.password.isEmpty {
            password = parts.password
        }
        profile.database = parts.database
        profile.tlsMode = parts.tlsMode
        if profile.name == "Local" || profile.name.isEmpty {
            profile.name = "\(parts.host):\(parts.port)"
        }
        pasteURL = ""
    }

    // MARK: Test Connection

    enum TestResult: Equatable {
        case testing
        case success(message: String)
        case failure(reason: String)
    }

    @ViewBuilder
    private func testResultView(_ r: TestResult) -> some View {
        switch r {
        case .testing:
            EmptyView()
        case .success(let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(msg)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        case .failure(let reason):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func runTest() {
        testResult = .testing
        let p = profile
        let pw = password
        Task { @MainActor in
            let result = await Self.probe(profile: p, password: pw)
            self.testResult = result
        }
    }

    /// Build a runner against the given profile, attempt to connect, run a
    /// queue discovery, then tear down. Returns a user-readable result.
    private static func probe(profile: RedisProfile, password: String) async -> TestResult {
        let tlsOrder: [Bool]
        switch profile.tlsMode {
        case .off:  tlsOrder = [false]
        case .on:   tlsOrder = [true]
        case .auto: tlsOrder = [true, false]
        }

        var lastError = "unknown"
        for (idx, useTLS) in tlsOrder.enumerated() {
            let hasFallback = idx + 1 < tlsOrder.count
            do {
                let runner = try await openRunner(profile: profile, password: password, useTLS: useTLS)
                let bull = BullMQService(client: runner, prefix: profile.bullPrefix)
                let queues = try await bull.discoverQueues()
                await runner.disconnect()
                let tlsLabel = useTLS ? " over TLS" : ""
                let qWord = queues.count == 1 ? "queue" : "queues"
                return .success(message: "Connected\(tlsLabel). \(queues.count) BullMQ \(qWord) found under prefix \"\(profile.bullPrefix)\".")
            } catch {
                lastError = error.localizedDescription
                let m = lastError.lowercased()
                let looksTLSish = m.contains("tls") || m.contains("handshake") || m.contains("ssl") || m.contains("reset")
                if looksTLSish && hasFallback { continue }
                return .failure(reason: lastError)
            }
        }
        return .failure(reason: lastError)
    }

    private static func openRunner(profile: RedisProfile, password: String, useTLS: Bool) async throws -> RedisCommandRunner {
        switch profile.mode {
        case .cluster:
            let seeds = profile.clusterSeeds.compactMap { HostPort.parse($0, fallback: 6379) }
            guard !seeds.isEmpty else { throw RedisError.connectionFailed("no cluster seeds") }
            let cluster = RedisClusterClient(
                seeds: seeds.map { ($0.host, $0.port) },
                tls: useTLS,
                username: profile.username.isEmpty ? nil : profile.username,
                password: password.isEmpty ? nil : password,
                database: profile.database
            )
            try await cluster.connect()
            return cluster
        case .standalone:
            let client = RedisClient(
                host: profile.host, port: UInt16(clamping: profile.port),
                tls: useTLS,
                username: profile.username.isEmpty ? nil : profile.username,
                password: password.isEmpty ? nil : password,
                database: profile.database
            )
            try await client.connect()
            return client
        case .sentinel:
            let hosts = profile.sentinelHosts.compactMap { HostPort.parse($0, fallback: 26379) }
            guard !hosts.isEmpty else { throw RedisError.connectionFailed("no sentinel hosts") }
            let client = RedisClient(
                target: .sentinel(
                    sentinels: hosts.map { (host: $0.host, port: $0.port) },
                    masterName: profile.sentinelMasterName,
                    sentinelPassword: password.isEmpty ? nil : password
                ),
                tls: useTLS,
                username: profile.username.isEmpty ? nil : profile.username,
                password: password.isEmpty ? nil : password,
                database: profile.database
            )
            try await client.connect()
            return client
        }
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
