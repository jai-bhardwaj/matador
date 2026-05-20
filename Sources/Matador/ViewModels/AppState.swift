import SwiftUI

enum ConnectionState: Equatable {
    case disconnected(String?)
    case connecting
    case reconnecting(retryIn: Int, attempt: Int)
    case connected
}

@MainActor
@Observable
final class AppState {
    // Profiles
    var profiles: [RedisProfile] = []
    var activeProfile: RedisProfile?

    // Connection
    var connectionState: ConnectionState = .disconnected(nil)
    var passwordPrompt: PasswordPrompt?

    // Queues
    var queues: [BullQueue] = []
    var selectedQueue: BullQueue?
    var queueSearch: String = ""

    // Jobs
    var selectedState: JobState = .waiting
    var jobs: [BullJobSummary] = []
    var jobSearch: String = ""
    var jobOffset: Int = 0
    let pageSize: Int = 50
    var jobsLoading: Bool = false
    var hasMore: Bool = false

    // Detail
    var selectedJobID: String?
    var jobDetail: BullJobDetail?
    var jobDetailLoading: Bool = false
    var jobChildren: JobChildren = .empty

    // View mode for the middle column: jobs / schedulers / workers / metrics
    var queueViewMode: QueueViewMode = .jobs
    var workers: [BullWorker] = []
    var workersLoading: Bool = false
    // Bulk selection
    var selectedJobIDs: Set<String> = []
    var schedulers: [BullScheduler] = []
    var selectedSchedulerID: String?
    var schedulersLoading: Bool = false

    // Toast
    var toastMessage: String?
    var toastIsError: Bool = false

    // Confirm
    var confirmAction: ConfirmAction?

    // Sheets
    var showProfileSheet: Bool = false
    var editingProfile: RedisProfile?
    var showAddJobSheet: Bool = false
    var showSettingsSheet: Bool = false
    var schedulerDetail: BullScheduler?  // when set, shows the scheduler detail sheet

    // Engine
    private var redis: RedisCommandRunner?
    private var bull: BullMQService?

    private var queuePollTask: Task<Void, Never>?
    private var jobPollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var sentinelMonitorTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    /// Monotonic generation per connect attempt. State mutations from a stale
    /// in-flight connect are dropped — only the most recent attempt can win.
    private var connectGeneration: Int = 0
    // Backoff schedule (seconds) for auto-reconnect.
    private let reconnectBackoff = [1, 2, 5, 10, 30, 60]

    init() {
        profiles = ProfileStore.shared.load()
        if profiles.isEmpty {
            profiles = [RedisProfile()]
            ProfileStore.shared.save(profiles)
        }
        if let lastID = ProfileStore.shared.loadLastUsed(),
           let p = profiles.first(where: { $0.id == lastID }) {
            activeProfile = p
        } else {
            activeProfile = profiles.first
        }
        registerShortcutObservers()
        celebrateIfJustUpdated()
    }

    /// One-shot "you're now on vX.Y.Z" toast right after the in-app updater
    /// swaps the binary and relaunches us. Compares persisted last-seen
    /// version with the bundled one.
    private func celebrateIfJustUpdated() {
        let key = "matador.lastSeenVersion"
        let previous = UserDefaults.standard.string(forKey: key)
        let current = AppConstants.version
        UserDefaults.standard.set(current, forKey: key)
        guard let previous = previous, previous != current else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.showToast("Updated v\(previous) → v\(current)")
        }
    }

    /// Wire main-menu CommandMenu items (which post via NotificationCenter)
    /// to AppState methods.
    private func registerShortcutObservers() {
        let c = NotificationCenter.default
        c.addObserver(forName: .matadorRefresh, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshQueues() }
        }
        c.addObserver(forName: .matadorTogglePause, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.togglePause() }
        }
        c.addObserver(forName: .matadorViewMode, object: nil, queue: .main) { [weak self] note in
            guard let mode = note.object as? QueueViewMode else { return }
            Task { @MainActor in await self?.setViewMode(mode) }
        }
        c.addObserver(forName: .matadorJobState, object: nil, queue: .main) { [weak self] note in
            guard let s = note.object as? JobState else { return }
            Task { @MainActor in await self?.setState(s) }
        }
        c.addObserver(forName: .matadorRetryJob, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.retrySelectedJob() }
        }
        c.addObserver(forName: .matadorPromoteJob, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.promoteSelectedJob() }
        }
        c.addObserver(forName: .matadorRemoveJob, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let id = self.selectedJobID, let q = self.selectedQueue else { return }
                self.confirmAction = ConfirmAction(
                    title: "Remove job?",
                    message: "Permanently remove #\(id) from \(q.name).",
                    destructive: true,
                    action: { Task { await self.removeSelectedJob() } }
                )
            }
        }
        c.addObserver(forName: .matadorAddJob, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showAddJobSheet = true }
        }
        c.addObserver(forName: .matadorSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showSettingsSheet = true }
        }
    }

    // MARK: Profile mgmt

    func saveProfile(_ profile: RedisProfile, password: String?) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        ProfileStore.shared.save(profiles)
        if let pw = password, !pw.isEmpty, profile.savePassword {
            try? Keychain.setPassword(pw, for: profile.id)
        }
    }

    func deleteProfile(_ profile: RedisProfile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.deletePassword(for: profile.id)
        ProfileStore.shared.save(profiles)
        if activeProfile?.id == profile.id {
            Task { await disconnect() }
            activeProfile = profiles.first
        }
    }

    func selectProfile(_ profile: RedisProfile) {
        guard activeProfile?.id != profile.id else { return }
        activeProfile = profile
        ProfileStore.shared.saveLastUsed(profile.id)
        // Cancel any in-flight connect first — profile switch always wins.
        connect()
    }

    /// Abort whatever the connection is doing right now and go to a clean
    /// disconnected state. Wired up to the "Cancel" button in the connecting hero.
    func cancelConnect() {
        connectGeneration += 1  // invalidate any in-flight attempt
        connectTask?.cancel(); connectTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        Task { @MainActor in
            await redis?.disconnect()
            redis = nil
            bull = nil
            connectionState = .disconnected("Cancelled")
        }
    }

    // MARK: Connect

    /// Kick off a connect attempt. Returns immediately; the work runs in a
    /// generation-tagged Task so newer attempts (profile switch, reconnect,
    /// cancel) can supersede this one cleanly.
    func connect(suppressAutoRetry: Bool = false) {
        if !suppressAutoRetry { reconnectTask?.cancel(); reconnectTask = nil }
        connectTask?.cancel()
        connectGeneration += 1
        let myGen = connectGeneration
        connectTask = Task { @MainActor [weak self] in
            await self?._connect(generation: myGen, suppressAutoRetry: suppressAutoRetry)
        }
    }

    /// Validate the profile before we burn 10s on a guaranteed-bad connect.
    private func validate(_ profile: RedisProfile) -> String? {
        switch profile.mode {
        case .standalone:
            if profile.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host is empty" }
            if !(1...65535).contains(profile.port) { return "Port \(profile.port) is out of range" }
        case .sentinel:
            if profile.sentinelHosts.isEmpty { return "No sentinel hosts configured" }
            if profile.sentinelMasterName.isEmpty { return "Sentinel master name is empty" }
        case .cluster:
            if profile.clusterSeeds.isEmpty { return "No cluster seed hosts configured" }
        }
        if profile.bullPrefix.trimmingCharacters(in: .whitespaces).isEmpty {
            return "BullMQ key prefix is empty"
        }
        return nil
    }

    private func _connect(generation: Int, suppressAutoRetry: Bool) async {
        guard let profile = activeProfile else {
            apply(generation: generation) { $0.connectionState = .disconnected("No profile selected") }
            return
        }
        if let err = validate(profile) {
            apply(generation: generation) { $0.connectionState = .disconnected(err) }
            return
        }

        // Tear down current state.
        healthCheckTask?.cancel(); healthCheckTask = nil
        sentinelMonitorTask?.cancel(); sentinelMonitorTask = nil
        queuePollTask?.cancel(); queuePollTask = nil
        jobPollTask?.cancel(); jobPollTask = nil
        await redis?.disconnect()
        redis = nil
        bull = nil

        // Only the current generation can flip state to .connecting.
        apply(generation: generation) { $0.connectionState = .connecting }

        var password: String? = nil
        if profile.savePassword {
            password = Keychain.getPassword(for: profile.id)
        } else {
            apply(generation: generation) { $0.passwordPrompt = PasswordPrompt(profile: profile) }
            return
        }

        await actuallyConnect(profile: profile, password: password, generation: generation)
    }

    func resumeConnect(with password: String?) async {
        guard let profile = passwordPrompt?.profile else { return }
        passwordPrompt = nil
        connectGeneration += 1
        let myGen = connectGeneration
        apply(generation: myGen) { $0.connectionState = .connecting }
        await actuallyConnect(profile: profile, password: password, generation: myGen)
    }

    /// Apply a state mutation only if our generation is still current.
    /// Prevents stale connect attempts from clobbering newer ones.
    private func apply(generation: Int, _ mutation: (AppState) -> Void) {
        guard generation == connectGeneration else { return }
        mutation(self)
    }

    /// Try opening a runner with each TLS setting in order. Only fall through
    /// to the next attempt when the error suggests the scheme is wrong — i.e.,
    /// the server hung up on us in a way consistent with a TLS-only or plain-only
    /// expectation. Errors like `connection refused`, `NOAUTH`, or `timed out`
    /// mean the network/auth is broken; retrying with a different TLS setting
    /// won't fix them and would just waste another timeout cycle.
    private func openWithTLSFallback(
        tlsOrder: [Bool],
        open: (Bool) async throws -> RedisCommandRunner
    ) async throws -> RedisCommandRunner {
        var lastError: Error?
        for (idx, useTLS) in tlsOrder.enumerated() {
            do {
                return try await open(useTLS)
            } catch {
                lastError = error
                let hasFallback = idx + 1 < tlsOrder.count
                if !hasFallback || !shouldFallbackToOtherTLSMode(error: error, triedTLS: useTLS) {
                    throw error
                }
                // else: silently try the next mode
            }
        }
        throw lastError ?? RedisError.connectionFailed("no TLS modes attempted")
    }

    /// Heuristic: was this error caused by us using the wrong TLS setting?
    /// - Plain → TLS-only server: typically `connection reset`, `eof`, or
    ///   `unexpected reply` (the server closes the socket the moment we send
    ///   non-TLS bytes).
    /// - TLS → plain server: typically `tls`/`handshake`/`ssl`/`certificate`
    ///   error, or a hard timeout (Redis ignores TLS ClientHello bytes).
    private func shouldFallbackToOtherTLSMode(error: Error, triedTLS: Bool) -> Bool {
        let msg = error.localizedDescription.lowercased()
        if triedTLS {
            // We tried TLS and it failed. Was it TLS-shaped?
            if msg.contains("tls") || msg.contains("handshake")
                || msg.contains("ssl") || msg.contains("certificate")
                || msg.contains("timed out") {
                return true
            }
            return false
        } else {
            // We tried plain TCP. Did the server close on us in a TLS-only way?
            if msg.contains("reset") || msg.contains("eof")
                || msg.contains("unexpected reply") || msg.contains("shutdown") {
                return true
            }
            return false
        }
    }

    private func actuallyConnect(profile: RedisProfile, password: String?, generation: Int) async {
        let runner: RedisCommandRunner
        do {
            let tlsOrder: [Bool]
            switch profile.tlsMode {
            case .off:  tlsOrder = [false]
            case .on:   tlsOrder = [true]
            // Plain first — port-forwards and local dev are almost always plain TCP,
            // and TLS-against-plain typically hangs until the 10s timeout, whereas
            // plain-against-TLS-only servers fail with `reset` in <100ms.
            case .auto: tlsOrder = [false, true]
            }

            switch profile.mode {
            case .cluster:
                let seeds = profile.clusterSeeds.compactMap { HostPort.parse($0, fallback: 6379) }
                guard !seeds.isEmpty else {
                    apply(generation: generation) { $0.connectionState = .disconnected("No cluster seed hosts configured") }
                    return
                }
                runner = try await openWithTLSFallback(tlsOrder: tlsOrder) { useTLS in
                    let cluster = RedisClusterClient(
                        seeds: seeds.map { ($0.host, $0.port) },
                        tls: useTLS,
                        username: profile.username.isEmpty ? nil : profile.username,
                        password: password,
                        database: profile.database
                    )
                    try await cluster.connect()
                    return cluster
                }

            case .standalone, .sentinel:
                let target: ConnectionTarget
                if profile.mode == .standalone {
                    target = .standalone(host: profile.host, port: UInt16(clamping: profile.port))
                } else {
                    let hosts = profile.sentinelHosts.compactMap { HostPort.parse($0, fallback: 26379) }
                    guard !hosts.isEmpty else {
                        apply(generation: generation) { $0.connectionState = .disconnected("No sentinel hosts configured") }
                        return
                    }
                    target = .sentinel(
                        sentinels: hosts.map { (host: $0.host, port: $0.port) },
                        masterName: profile.sentinelMasterName,
                        sentinelPassword: password
                    )
                }
                runner = try await openWithTLSFallback(tlsOrder: tlsOrder) { useTLS in
                    let client = RedisClient(
                        target: target,
                        tls: useTLS,
                        username: profile.username.isEmpty ? nil : profile.username,
                        password: password,
                        database: profile.database
                    )
                    try await client.connect()
                    return client
                }
            }

            // Stale generation? A newer connect won the race; tear this down.
            guard generation == connectGeneration else {
                await runner.disconnect()
                return
            }

            self.redis = runner
            self.bull = BullMQService(client: runner, prefix: profile.bullPrefix)
            connectionState = .connected
            ProfileStore.shared.saveLastUsed(profile.id)
            await refreshQueues()
            startQueuePolling()
            startHealthCheck()
            if profile.mode == .sentinel { startSentinelMonitor(profile: profile, password: password) }
        } catch {
            // Stale generation? Drop the error silently — the new attempt owns the UI.
            guard generation == connectGeneration else { return }
            self.redis = nil
            self.bull = nil
            connectionState = .disconnected(error.localizedDescription)
            if activeProfile != nil {
                scheduleReconnect(after: error)
            }
        }
    }

    /// Health probe: PING every 4s. On failure, treat as disconnected and
    /// kick off the reconnect loop.
    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self = self else { return }
                let runner = await MainActor.run { self.redis }
                guard let runner = runner else { return }
                do {
                    _ = try await runner.send("PING", [])
                } catch {
                    await MainActor.run { self.handleConnectionLoss(reason: error.localizedDescription) }
                    return
                }
            }
        }
    }

    /// Called by health check or by any command that finds the socket dead.
    private func handleConnectionLoss(reason: String) {
        guard case .connected = connectionState else { return }
        queuePollTask?.cancel(); queuePollTask = nil
        jobPollTask?.cancel(); jobPollTask = nil
        healthCheckTask?.cancel(); healthCheckTask = nil
        sentinelMonitorTask?.cancel(); sentinelMonitorTask = nil
        Task { await redis?.disconnect() }
        redis = nil
        bull = nil
        scheduleReconnect(after: nil, message: "Lost connection: \(reason)")
    }

    private func scheduleReconnect(after error: Error? = nil, message: String? = nil) {
        guard activeProfile != nil else { return }
        reconnectTask?.cancel()
        if let m = message { showToast(m, isError: true) }

        reconnectTask = Task { [weak self] in
            guard let self = self else { return }
            for (attempt, seconds) in await MainActor.run(body: { self.reconnectBackoff.enumerated().map { ($0.offset + 1, $0.element) } }) {
                if Task.isCancelled { return }
                // Countdown so the UI shows "reconnecting in 3s"
                for remaining in stride(from: seconds, through: 1, by: -1) {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.connectionState = .reconnecting(retryIn: remaining, attempt: attempt)
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if Task.isCancelled { return }
                // Try once — fire-and-wait via polling for the result. connect()
                // is now sync (spawns its own task) so we await its outcome by
                // watching connectionState until it's no longer .connecting.
                await MainActor.run { self.connect(suppressAutoRetry: true) }
                while await MainActor.run(body: {
                    if case .connecting = self.connectionState { return true }
                    return false
                }) {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                let connected = await MainActor.run { self.connectionState == .connected }
                if connected { return }
            }
            // Backoff exhausted — leave in disconnected with a final message
            await MainActor.run {
                if case .reconnecting = self.connectionState {
                    self.connectionState = .disconnected("Giving up after \(self.reconnectBackoff.count) attempts.")
                }
            }
        }
    }

    /// Periodically ask sentinels for the current master; force a reconnect if
    /// it differs from the address we're currently using.
    private func startSentinelMonitor(profile: RedisProfile, password: String?) {
        sentinelMonitorTask?.cancel()
        let hosts = profile.sentinelHosts.compactMap { HostPort.parse($0, fallback: 26379) }
        guard !hosts.isEmpty else { return }
        let masterName = profile.sentinelMasterName

        sentinelMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
                guard let self = self else { return }
                guard let runner = await MainActor.run(body: { self.redis }) else { return }
                // Find current master across the configured sentinels.
                var currentMaster: (String, UInt16)?
                for sentinel in hosts {
                    let probe = RedisClient(
                        host: sentinel.host, port: sentinel.port, tls: false,
                        username: nil, password: password, database: 0
                    )
                    do {
                        try await probe.connect()
                        let reply = try await probe.send("SENTINEL", ["get-master-addr-by-name", masterName])
                        await probe.disconnect()
                        if case .array(let arr?) = reply, arr.count == 2,
                           let h = arr[0].stringValue, let p = arr[1].stringValue.flatMap({ UInt16($0) }) {
                            currentMaster = (h, p)
                            break
                        }
                    } catch {
                        await probe.disconnect()
                        continue
                    }
                }
                guard let resolved = currentMaster else { continue }
                // Compare to what RedisClient resolved at connect time
                if let client = runner as? RedisClient {
                    let knownHost = await client.resolvedHost
                    let knownPort = await client.resolvedPort
                    if knownHost != resolved.0 || knownPort != resolved.1 {
                        await MainActor.run {
                            self.showToast("Sentinel reports new master \(resolved.0):\(resolved.1) — reconnecting", isError: false)
                            self.handleConnectionLoss(reason: "Sentinel failover")
                        }
                        return
                    }
                }
            }
        }
    }

    func disconnect() async {
        reconnectTask?.cancel(); reconnectTask = nil
        healthCheckTask?.cancel(); healthCheckTask = nil
        sentinelMonitorTask?.cancel(); sentinelMonitorTask = nil
        queuePollTask?.cancel(); queuePollTask = nil
        jobPollTask?.cancel(); jobPollTask = nil
        await redis?.disconnect()
        redis = nil
        bull = nil
        queues = []
        selectedQueue = nil
        jobs = []
        jobDetail = nil
        selectedJobID = nil
        connectionState = .disconnected(nil)
    }

    // MARK: Queues

    func refreshQueues() async {
        guard let bull = bull else { return }
        do {
            var found = try await bull.discoverQueues()
            for i in 0..<found.count {
                if let (c, paused, stalled) = try? await bull.counts(for: found[i].name) {
                    found[i].counts = c
                    found[i].isPaused = paused
                    found[i].stalledCount = stalled
                }
            }
            self.queues = found
            if let sel = selectedQueue, let updated = found.first(where: { $0.id == sel.id }) {
                self.selectedQueue = updated
            } else if let first = found.first, selectedQueue == nil {
                await selectQueue(first)
            }
            recordSamplesForChart()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func selectQueue(_ queue: BullQueue) async {
        selectedQueue = queue
        selectedJobID = nil
        jobDetail = nil
        jobChildren = .empty
        jobOffset = 0
        selectedSchedulerID = nil
        schedulers = []
        if queueViewMode == .jobs {
            await refreshJobs()
        } else {
            await refreshSchedulers()
        }
        startJobPolling()
    }

    func setViewMode(_ mode: QueueViewMode) async {
        queueViewMode = mode
        switch mode {
        case .jobs: await refreshJobs()
        case .schedulers: await refreshSchedulers()
        case .workers: await refreshWorkers()
        case .metrics: break // chart reads MetricsStore directly
        }
    }

    func setState(_ state: JobState) async {
        selectedState = state
        selectedJobID = nil
        jobDetail = nil
        jobOffset = 0
        await refreshJobs()
    }

    func refreshJobs(append: Bool = false) async {
        guard let bull = bull, let q = selectedQueue else { return }
        if !append { jobsLoading = true }
        defer { if !append { jobsLoading = false } }
        do {
            let ids = try await bull.jobIds(
                queue: q.name, state: selectedState,
                offset: jobOffset, limit: pageSize
            )
            let summaries = try await bull.summarize(queue: q.name, state: selectedState, ids: ids)
            if append {
                jobs.append(contentsOf: summaries)
            } else {
                jobs = summaries
            }
            hasMore = summaries.count == pageSize
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func loadMoreJobs() async {
        guard hasMore, !jobsLoading else { return }
        jobOffset += pageSize
        await refreshJobs(append: true)
    }

    // MARK: Job detail

    func selectJob(_ id: String) async {
        selectedJobID = id
        await loadJobDetail()
    }

    func loadJobDetail() async {
        guard let bull = bull, let q = selectedQueue, let id = selectedJobID else { return }
        jobDetailLoading = true
        defer { jobDetailLoading = false }
        do {
            jobDetail = try await bull.jobDetail(queue: q.name, id: id)
            // Lazy: also look up children. They're cheap (two small commands) and
            // a viewer that doesn't show flow context isn't worth shipping.
            async let unresolved = bull.unresolvedChildren(queue: q.name, id: id)
            async let resolved = bull.resolvedChildren(queue: q.name, id: id)
            jobChildren = JobChildren(
                unresolved: (try? await unresolved) ?? [],
                resolved: (try? await resolved) ?? []
            )
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: Schedulers

    func refreshSchedulers() async {
        guard let bull = bull, let q = selectedQueue else { return }
        schedulersLoading = true
        defer { schedulersLoading = false }
        do {
            schedulers = try await bull.listSchedulers(queue: q.name)
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func removeScheduler(id: String) async {
        guard let bull = bull, let q = selectedQueue else { return }
        do {
            try await bull.removeScheduler(queue: q.name, id: id)
            showToast("Removed scheduler \(id)")
            if selectedSchedulerID == id { selectedSchedulerID = nil }
            await refreshSchedulers()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: Mutations

    func retrySelectedJob() async {
        guard let bull = bull, let q = selectedQueue, let id = selectedJobID else { return }
        do {
            try await bull.retryFailed(queue: q.name, id: id)
            showToast("Retried \(id)")
            await refreshJobs()
            await loadJobDetail()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func promoteSelectedJob() async {
        guard let bull = bull, let q = selectedQueue, let id = selectedJobID else { return }
        do {
            try await bull.promoteDelayed(queue: q.name, id: id)
            showToast("Promoted \(id)")
            await refreshJobs()
            await loadJobDetail()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func removeSelectedJob() async {
        guard let bull = bull, let q = selectedQueue, let id = selectedJobID else { return }
        do {
            try await bull.removeJob(queue: q.name, id: id, force: true)
            showToast("Removed \(id)")
            selectedJobID = nil
            jobDetail = nil
            await refreshJobs()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func togglePause() async {
        guard let bull = bull, let q = selectedQueue else { return }
        do {
            if q.isPaused {
                try await bull.resume(queue: q.name)
                showToast("Resumed \(q.name)")
            } else {
                try await bull.pause(queue: q.name)
                showToast("Paused \(q.name)")
            }
            await refreshQueues()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func cleanCurrentState(limit: Int = 1000) async {
        guard let bull = bull, let q = selectedQueue else { return }
        do {
            let n = try await bull.clean(queue: q.name, state: selectedState, limit: limit)
            showToast("Cleaned \(n) job\(n == 1 ? "" : "s")")
            await refreshJobs()
            await refreshQueues()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func drainCurrentQueue() async {
        guard let bull = bull, let q = selectedQueue else { return }
        do {
            let n = try await bull.drain(queue: q.name)
            showToast("Drained \(n) job\(n == 1 ? "" : "s")")
            await refreshJobs()
            await refreshQueues()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: Polling

    private func startQueuePolling() {
        queuePollTask?.cancel()
        queuePollTask = Task { [weak self] in
            while !Task.isCancelled {
                let s = await MainActor.run { Settings.shared.queuePollSeconds }
                try? await Task.sleep(nanoseconds: UInt64(s) * 1_000_000_000)
                await self?.refreshQueueCounts()
            }
        }
    }

    private func refreshQueueCounts() async {
        guard let bull = bull, !queues.isEmpty else { return }
        for i in 0..<queues.count {
            if let (c, paused, stalled) = try? await bull.counts(for: queues[i].name) {
                queues[i].counts = c
                queues[i].isPaused = paused
                queues[i].stalledCount = stalled
                if selectedQueue?.id == queues[i].id {
                    selectedQueue = queues[i]
                }
            }
        }
        recordSamplesForChart()
    }

    private func startJobPolling() {
        jobPollTask?.cancel()
        jobPollTask = Task { [weak self] in
            while !Task.isCancelled {
                let s = await MainActor.run { Settings.shared.jobPollSeconds }
                try? await Task.sleep(nanoseconds: UInt64(s) * 1_000_000_000)
                guard let self = self else { return }
                if await MainActor.run(body: { self.jobOffset == 0 && self.selectedJobID == nil }) {
                    await self.refreshJobs()
                }
            }
        }
    }

    // MARK: Add Job

    func addJob(queueName: String, name: String, data: String, priority: Int, delayMs: Int64, attempts: Int) async {
        guard let bull = bull else { return }
        do {
            let id = try await bull.addJob(
                queue: queueName, name: name, data: data,
                priority: priority, delayMs: delayMs, attempts: attempts
            )
            showToast("Added #\(id) to \(queueName)")
            await refreshQueues()
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: Metrics

    func recordSamplesForChart() {
        let now = Date()
        for q in queues {
            let sample = QueueSample(
                timestamp: now,
                counts: q.counts,
                stalled: q.stalledCount,
                workers: q.workerCount
            )
            MetricsStore.shared.record(queueID: q.id, sample: sample)
        }
    }

    // MARK: Workers

    func refreshWorkers() async {
        guard let bull = bull, let q = selectedQueue else { return }
        workersLoading = true
        defer { workersLoading = false }
        do {
            workers = try await bull.listWorkers(queue: q.name)
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: Bulk actions

    func toggleJobSelection(_ id: String) {
        if selectedJobIDs.contains(id) { selectedJobIDs.remove(id) }
        else { selectedJobIDs.insert(id) }
    }

    func clearJobSelection() { selectedJobIDs.removeAll() }

    func selectAllVisibleJobs() {
        selectedJobIDs = Set(jobs.map { $0.id })
    }

    func bulkRetry() async {
        guard let bull = bull, let q = selectedQueue, !selectedJobIDs.isEmpty else { return }
        var ok = 0
        let ids = Array(selectedJobIDs)
        for id in ids {
            do { try await bull.retryFailed(queue: q.name, id: id); ok += 1 } catch {}
        }
        showToast("Retried \(ok)/\(ids.count)")
        selectedJobIDs.removeAll()
        await refreshJobs()
    }

    func bulkPromote() async {
        guard let bull = bull, let q = selectedQueue, !selectedJobIDs.isEmpty else { return }
        var ok = 0
        let ids = Array(selectedJobIDs)
        for id in ids {
            do { try await bull.promoteDelayed(queue: q.name, id: id); ok += 1 } catch {}
        }
        showToast("Promoted \(ok)/\(ids.count)")
        selectedJobIDs.removeAll()
        await refreshJobs()
    }

    func bulkRemove() async {
        guard let bull = bull, let q = selectedQueue, !selectedJobIDs.isEmpty else { return }
        var ok = 0
        let ids = Array(selectedJobIDs)
        for id in ids {
            do { try await bull.removeJob(queue: q.name, id: id, force: true); ok += 1 } catch {}
        }
        showToast("Removed \(ok)/\(ids.count)")
        selectedJobIDs.removeAll()
        await refreshJobs()
    }

    // MARK: Toast

    func showToast(_ message: String, isError: Bool = false) {
        toastMessage = message
        toastIsError = isError
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                if self?.toastMessage == message { self?.toastMessage = nil }
            }
        }
    }
}

// MARK: - Supporting types

struct ConfirmAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let destructive: Bool
    let action: () -> Void
}

struct PasswordPrompt: Identifiable {
    let id = UUID()
    let profile: RedisProfile
}

// MARK: - Notification names (driven by main-menu shortcuts)

extension Notification.Name {
    static let matadorRefresh      = Notification.Name("matador.refresh")
    static let matadorTogglePause  = Notification.Name("matador.togglePause")
    static let matadorViewMode     = Notification.Name("matador.viewMode")
    static let matadorJobState     = Notification.Name("matador.jobState")
    static let matadorRetryJob     = Notification.Name("matador.retryJob")
    static let matadorPromoteJob   = Notification.Name("matador.promoteJob")
    static let matadorRemoveJob    = Notification.Name("matador.removeJob")
    static let matadorAddJob       = Notification.Name("matador.addJob")
    static let matadorSettings     = Notification.Name("matador.settings")
}

enum QueueViewMode: String, Hashable, CaseIterable, Identifiable {
    case jobs, schedulers, workers, metrics
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jobs: return "Jobs"
        case .schedulers: return "Schedulers"
        case .workers: return "Workers"
        case .metrics: return "Metrics"
        }
    }
    var icon: String {
        switch self {
        case .jobs: return "list.bullet"
        case .schedulers: return "calendar"
        case .workers: return "cpu"
        case .metrics: return "chart.xyaxis.line"
        }
    }
}

struct JobChildren: Equatable {
    var unresolved: [String]
    var resolved: [String]
    static let empty = JobChildren(unresolved: [], resolved: [])
}
