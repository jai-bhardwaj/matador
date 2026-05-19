import SwiftUI

enum ConnectionState: Equatable {
    case disconnected(String?)
    case connecting
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

    // View mode for the middle column: jobs or schedulers
    var queueViewMode: QueueViewMode = .jobs
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

    // Engine
    private var redis: RedisCommandRunner?
    private var bull: BullMQService?

    private var queuePollTask: Task<Void, Never>?
    private var jobPollTask: Task<Void, Never>?

    init() {
        profiles = ProfileStore.shared.load()
        // Seed a default profile if empty so the UI isn't blank on first launch.
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
        Task { await connect() }
    }

    // MARK: Connect

    func connect() async {
        guard let profile = activeProfile else {
            connectionState = .disconnected("No profile selected")
            return
        }
        await disconnect()
        connectionState = .connecting

        var password: String? = nil
        if profile.savePassword {
            password = Keychain.getPassword(for: profile.id)
        }
        if profile.savePassword == false {
            // Prompt and bail out — UI will call resumeConnect(with:) when user submits.
            passwordPrompt = PasswordPrompt(profile: profile)
            return
        }

        await actuallyConnect(profile: profile, password: password)
    }

    func resumeConnect(with password: String?) async {
        guard let profile = passwordPrompt?.profile else { return }
        passwordPrompt = nil
        connectionState = .connecting
        await actuallyConnect(profile: profile, password: password)
    }

    private func actuallyConnect(profile: RedisProfile, password: String?) async {
        let runner: RedisCommandRunner
        do {
            switch profile.mode {
            case .cluster:
                let seeds = profile.clusterSeeds.compactMap { HostPort.parse($0, fallback: 6379) }
                guard !seeds.isEmpty else {
                    connectionState = .disconnected("No cluster seed hosts configured")
                    return
                }
                let cluster = RedisClusterClient(
                    seeds: seeds.map { ($0.host, $0.port) },
                    tls: profile.tls,
                    username: profile.username.isEmpty ? nil : profile.username,
                    password: password,
                    database: profile.database
                )
                try await cluster.connect()
                runner = cluster

            case .standalone, .sentinel:
                let target: ConnectionTarget
                if profile.mode == .standalone {
                    target = .standalone(host: profile.host, port: UInt16(clamping: profile.port))
                } else {
                    let hosts = profile.sentinelHosts.compactMap { HostPort.parse($0, fallback: 26379) }
                    guard !hosts.isEmpty else {
                        connectionState = .disconnected("No sentinel hosts configured")
                        return
                    }
                    target = .sentinel(
                        sentinels: hosts.map { (host: $0.host, port: $0.port) },
                        masterName: profile.sentinelMasterName,
                        sentinelPassword: password
                    )
                }
                let client = RedisClient(
                    target: target,
                    tls: profile.tls,
                    username: profile.username.isEmpty ? nil : profile.username,
                    password: password,
                    database: profile.database
                )
                try await client.connect()
                runner = client
            }

            self.redis = runner
            self.bull = BullMQService(client: runner, prefix: profile.bullPrefix)
            connectionState = .connected
            ProfileStore.shared.saveLastUsed(profile.id)
            await refreshQueues()
            startQueuePolling()
        } catch {
            self.redis = nil
            self.bull = nil
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func disconnect() async {
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
            // hydrate counts in parallel-ish (sequential pipelines, but fast)
            for i in 0..<found.count {
                if let (c, paused) = try? await bull.counts(for: found[i].name) {
                    found[i].counts = c
                    found[i].isPaused = paused
                }
            }
            self.queues = found
            // Re-select the same queue if still present
            if let sel = selectedQueue, let updated = found.first(where: { $0.id == sel.id }) {
                self.selectedQueue = updated
            } else if let first = found.first, selectedQueue == nil {
                await selectQueue(first)
            }
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
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                await self?.refreshQueueCounts()
            }
        }
    }

    private func refreshQueueCounts() async {
        guard let bull = bull, !queues.isEmpty else { return }
        for i in 0..<queues.count {
            if let (c, paused) = try? await bull.counts(for: queues[i].name) {
                queues[i].counts = c
                queues[i].isPaused = paused
                if selectedQueue?.id == queues[i].id {
                    selectedQueue = queues[i]
                }
            }
        }
    }

    private func startJobPolling() {
        jobPollTask?.cancel()
        jobPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s
                guard let self = self else { return }
                // Only auto-refresh job list when we're at the top of the page
                if await MainActor.run(body: { self.jobOffset == 0 && self.selectedJobID == nil }) {
                    await self.refreshJobs()
                }
            }
        }
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

enum QueueViewMode: String, Hashable, CaseIterable, Identifiable {
    case jobs, schedulers
    var id: String { rawValue }
    var label: String { self == .jobs ? "Jobs" : "Schedulers" }
}

struct JobChildren: Equatable {
    var unresolved: [String]
    var resolved: [String]
    static let empty = JobChildren(unresolved: [], resolved: [])
}
