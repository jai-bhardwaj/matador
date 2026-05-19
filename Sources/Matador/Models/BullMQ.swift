import Foundation

// MARK: - Models

enum JobState: String, CaseIterable, Identifiable, Hashable {
    case waiting
    case active
    case completed
    case failed
    case delayed
    case prioritized
    case paused
    case waitingChildren = "waiting-children"

    var id: String { rawValue }

    /// Display label.
    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .active: return "Active"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .delayed: return "Delayed"
        case .prioritized: return "Prioritized"
        case .paused: return "Paused"
        case .waitingChildren: return "Waiting Children"
        }
    }

    /// The Redis key segment under `bull:<queue>:<segment>`.
    var keySegment: String {
        switch self {
        case .waitingChildren: return "waiting-children"
        default: return rawValue
        }
    }

    /// How BullMQ stores this state's job ids.
    var storage: JobStateStorage {
        switch self {
        case .waiting, .paused: return .list
        case .active: return .list
        case .completed, .failed, .delayed, .prioritized, .waitingChildren: return .zset
        }
    }
}

enum JobStateStorage { case list, zset }

struct BullQueue: Identifiable, Hashable {
    let id: String      // "<prefix>:<name>"
    let prefix: String  // typically "bull"
    let name: String
    var counts: [JobState: Int] = [:]
    var isPaused: Bool = false
    var stalledCount: Int = 0
    var workerCount: Int = 0

    var totalActive: Int { (counts[.waiting] ?? 0) + (counts[.active] ?? 0) + (counts[.delayed] ?? 0) }
}

struct BullJobSummary: Identifiable, Hashable {
    let id: String
    let queueKey: String     // "<prefix>:<name>"
    let state: JobState
    let name: String?        // bullmq stores the job name in the hash; we hydrate this lazily
    let timestamp: Date?
    let progress: Double?
    let attemptsMade: Int?
    let failedReason: String?

    var displayName: String { name ?? "(unnamed)" }
}

struct BullJobDetail: Hashable {
    let id: String
    let name: String
    let queueKey: String
    let data: String          // raw JSON string from hash field
    let opts: String
    let returnvalue: String
    let stacktrace: [String]
    let failedReason: String?
    let timestamp: Date?
    let processedOn: Date?
    let finishedOn: Date?
    let attemptsMade: Int
    let delay: Int64
    let priority: Int64?
    let parent: String?
    let logs: [String]
    let raw: [String: String]
}

// MARK: - BullMQ key helpers

enum BullKeys {
    /// Full prefix used as the queue base key, e.g. "bull:emails"
    static func base(prefix: String, queue: String) -> String { "\(prefix):\(queue)" }

    static func meta(prefix: String, queue: String) -> String { "\(base(prefix: prefix, queue: queue)):meta" }
    static func list(prefix: String, queue: String, state: JobState) -> String {
        "\(base(prefix: prefix, queue: queue)):\(state.keySegment)"
    }
    static func pausedFlag(prefix: String, queue: String) -> String {
        "\(base(prefix: prefix, queue: queue)):paused"
    }
    static func job(prefix: String, queue: String, id: String) -> String {
        "\(base(prefix: prefix, queue: queue)):\(id)"
    }
    static func logs(prefix: String, queue: String, id: String) -> String {
        "\(base(prefix: prefix, queue: queue)):\(id):logs"
    }
    static func dependencies(prefix: String, queue: String, id: String) -> String {
        "\(base(prefix: prefix, queue: queue)):\(id):dependencies"
    }
    static func processed(prefix: String, queue: String, id: String) -> String {
        "\(base(prefix: prefix, queue: queue)):\(id):processed"
    }
    static func repeatZset(prefix: String, queue: String) -> String {
        "\(base(prefix: prefix, queue: queue)):repeat"
    }
    static func scheduler(prefix: String, queue: String, id: String) -> String {
        "\(base(prefix: prefix, queue: queue)):repeat:\(id)"
    }
    static func stalledCheck(prefix: String, queue: String) -> String {
        "\(base(prefix: prefix, queue: queue)):stalled-check"
    }
    static func stalled(prefix: String, queue: String) -> String {
        "\(base(prefix: prefix, queue: queue)):stalled"
    }
    static func eventsStream(prefix: String, queue: String) -> String {
        "\(base(prefix: prefix, queue: queue)):events"
    }
    static func idCounter(prefix: String, queue: String) -> String {
        "\(base(prefix: prefix, queue: queue)):id"
    }
}

// MARK: - Scheduler model

struct BullWorker: Identifiable, Hashable {
    let id: String       // CLIENT id from Redis
    let name: String     // SETNAME value, e.g. "bull:emails:worker:abc"
    let addr: String     // "ip:port"
    let idleSeconds: Int
    let age: Int

    var displayName: String {
        // Strip "bull:<queue>:" prefix if present so the row reads cleanly.
        if let lastColon = name.lastIndex(of: ":") {
            return String(name[name.index(after: lastColon)...])
        }
        return name
    }
}

struct BullScheduler: Identifiable, Hashable {
    let id: String
    let queueKey: String
    let name: String?
    let pattern: String?     // cron pattern (e.g. "0 * * * *") if defined
    let every: Int64?        // ms interval if defined
    let tz: String?
    let endDate: Date?
    let limit: Int?
    let nextRun: Date?

    var cadence: String {
        if let p = pattern, !p.isEmpty { return "cron: \(p)" }
        if let e = every { return "every \(e)ms" }
        return "—"
    }
}

// MARK: - BullMQService
//
// High-level operations against a connected RedisClient.

actor BullMQService {
    private let client: RedisCommandRunner
    private(set) var prefix: String

    init(client: RedisCommandRunner, prefix: String = "bull") {
        self.client = client
        self.prefix = prefix
    }

    // MARK: Queue discovery

    /// Scan Redis for `<prefix>:*:meta` keys and return queue names. In cluster
    /// mode this scans every master shard.
    func discoverQueues() async throws -> [BullQueue] {
        let metaKeys = try await client.scanAll(matching: "\(prefix):*:meta")
        var names = Set<String>()
        for k in metaKeys {
            if let n = extractQueueName(from: k) { names.insert(n) }
        }
        return names.sorted().map { BullQueue(id: "\(prefix):\($0)", prefix: prefix, name: $0) }
    }

    private func extractQueueName(from metaKey: String) -> String? {
        // metaKey = "<prefix>:<name>:meta" — strip both ends
        let leading = "\(prefix):"
        let trailing = ":meta"
        guard metaKey.hasPrefix(leading), metaKey.hasSuffix(trailing) else { return nil }
        let start = metaKey.index(metaKey.startIndex, offsetBy: leading.count)
        let end = metaKey.index(metaKey.endIndex, offsetBy: -trailing.count)
        guard start < end else { return nil }
        return String(metaKey[start..<end])
    }

    // MARK: Counts

    /// Pipelined count across all states + pause flag + stalled count.
    func counts(for queue: String) async throws -> (counts: [JobState: Int], paused: Bool, stalled: Int) {
        let states = JobState.allCases
        var commands: [(String, [Any])] = []
        for s in states {
            let key = BullKeys.list(prefix: prefix, queue: queue, state: s)
            commands.append((s.storage == .list ? "LLEN" : "ZCARD", [key]))
        }
        commands.append(("HGET", [BullKeys.meta(prefix: prefix, queue: queue), "paused"]))
        commands.append(("SCARD", [BullKeys.stalled(prefix: prefix, queue: queue)]))

        let replies = try await client.pipeline(commands)
        var counts: [JobState: Int] = [:]
        for (i, s) in states.enumerated() {
            counts[s] = Int(replies[i].intValue ?? 0)
        }
        let paused: Bool = {
            if let s = replies[states.count].stringValue, s == "1" || s == "true" { return true }
            return false
        }()
        let stalled = Int(replies.last?.intValue ?? 0)
        return (counts, paused, stalled)
    }

    // MARK: Job listing

    /// Return job ids for a given state, paginated.
    func jobIds(queue: String, state: JobState, offset: Int, limit: Int) async throws -> [String] {
        let key = BullKeys.list(prefix: prefix, queue: queue, state: state)
        let stop = offset + limit - 1
        let reply: RESPValue
        switch state.storage {
        case .list:
            reply = try await client.send("LRANGE", [key, offset, stop])
        case .zset:
            // newest-first for completed/failed; ascending for delayed (next-to-fire first)
            if state == .delayed {
                reply = try await client.send("ZRANGE", [key, offset, stop])
            } else {
                reply = try await client.send("ZREVRANGE", [key, offset, stop])
            }
        }
        guard case .array(let arr?) = reply else { return [] }
        return arr.compactMap { $0.stringValue }
    }

    /// Hydrate summaries by HMGET on each job hash (in one pipeline).
    func summarize(queue: String, state: JobState, ids: [String]) async throws -> [BullJobSummary] {
        guard !ids.isEmpty else { return [] }
        let fields = ["name", "timestamp", "progress", "attemptsMade", "failedReason"]
        let commands: [(String, [Any])] = ids.map { id in
            ("HMGET", [BullKeys.job(prefix: prefix, queue: queue, id: id)] + fields)
        }
        let replies = try await client.pipeline(commands)
        var out: [BullJobSummary] = []
        out.reserveCapacity(ids.count)
        for (id, reply) in zip(ids, replies) {
            guard case .array(let arr?) = reply, arr.count == fields.count else {
                out.append(BullJobSummary(
                    id: id, queueKey: "\(prefix):\(queue)", state: state,
                    name: nil, timestamp: nil, progress: nil, attemptsMade: nil, failedReason: nil
                ))
                continue
            }
            let name = arr[0].stringValue
            let ts = arr[1].stringValue.flatMap { Int64($0) }.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            let progress: Double? = {
                guard let s = arr[2].stringValue else { return nil }
                return Double(s)
            }()
            let attempts = arr[3].stringValue.flatMap { Int($0) }
            let failed = arr[4].stringValue
            out.append(BullJobSummary(
                id: id, queueKey: "\(prefix):\(queue)", state: state,
                name: name, timestamp: ts, progress: progress, attemptsMade: attempts, failedReason: failed
            ))
        }
        return out
    }

    // MARK: Job detail

    func jobDetail(queue: String, id: String) async throws -> BullJobDetail? {
        let key = BullKeys.job(prefix: prefix, queue: queue, id: id)
        let logsKey = BullKeys.logs(prefix: prefix, queue: queue, id: id)
        let replies = try await client.pipeline([
            ("HGETALL", [key]),
            ("LRANGE", [logsKey, 0, 500]),
        ])
        guard case .array(let arr?) = replies[0], !arr.isEmpty else { return nil }

        var dict: [String: String] = [:]
        var i = 0
        while i + 1 < arr.count {
            if let k = arr[i].stringValue, let v = arr[i + 1].stringValue {
                dict[k] = v
            }
            i += 2
        }

        let logs: [String] = {
            if case .array(let a?) = replies[1] {
                return a.compactMap { $0.stringValue }
            }
            return []
        }()

        let stacktrace: [String] = {
            guard let raw = dict["stacktrace"],
                  let data = raw.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return [] }
            return arr
        }()

        func toDate(_ s: String?) -> Date? {
            guard let s = s, let ms = Int64(s) else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        }

        return BullJobDetail(
            id: id,
            name: dict["name"] ?? "(unnamed)",
            queueKey: "\(prefix):\(queue)",
            data: dict["data"] ?? "",
            opts: dict["opts"] ?? "",
            returnvalue: dict["returnvalue"] ?? "",
            stacktrace: stacktrace,
            failedReason: dict["failedReason"],
            timestamp: toDate(dict["timestamp"]),
            processedOn: toDate(dict["processedOn"]),
            finishedOn: toDate(dict["finishedOn"]),
            attemptsMade: Int(dict["attemptsMade"] ?? "") ?? 0,
            delay: Int64(dict["delay"] ?? "") ?? 0,
            priority: Int64(dict["priority"] ?? ""),
            parent: dict["parent"],
            logs: logs,
            raw: dict
        )
    }

    // MARK: Mutations
    //
    // All mutations run as Lua scripts via EVALSHA so the key moves are atomic
    // against concurrent workers. Scripts live in Sources/Matador/Resources/lua/
    // and are loaded into the binary at build time.

    /// Remove a job entirely (hash + logs + ids in any state set).
    /// Refuses to remove if the job is currently active and `force` is false.
    func removeJob(queue: String, id: String, force: Bool = false) async throws {
        let stateKeys = JobState.allCases.map { BullKeys.list(prefix: prefix, queue: queue, state: $0) }
        let jobKey = BullKeys.job(prefix: prefix, queue: queue, id: id)
        let logsKey = BullKeys.logs(prefix: prefix, queue: queue, id: id)
        let keys = stateKeys + [jobKey, logsKey]

        // kinds string: 1=list, 0=zset, one char per state key
        let kinds = JobState.allCases.map { $0.storage == .list ? "1" : "0" }.joined()
        let activeIdx = (JobState.allCases.firstIndex(of: .active) ?? -1) + 1 // 1-based for Lua

        let reply = try await client.evalScript(LuaScripts.removeJob,
            keys: keys,
            args: [id, kinds, force ? "1" : "0", activeIdx])
        if reply.intValue == -1 {
            throw RedisError.commandFailed("Refused to remove active job. Use force.")
        }
    }

    /// Move a failed job back to wait.
    func retryFailed(queue: String, id: String) async throws {
        let keys = [
            BullKeys.list(prefix: prefix, queue: queue, state: .failed),
            BullKeys.list(prefix: prefix, queue: queue, state: .waiting),
            BullKeys.job(prefix: prefix, queue: queue, id: id),
        ]
        _ = try await client.evalScript(LuaScripts.retry, keys: keys, args: [id])
    }

    /// Promote a delayed job to wait immediately.
    func promoteDelayed(queue: String, id: String) async throws {
        let keys = [
            BullKeys.list(prefix: prefix, queue: queue, state: .delayed),
            BullKeys.list(prefix: prefix, queue: queue, state: .waiting),
            BullKeys.job(prefix: prefix, queue: queue, id: id),
        ]
        _ = try await client.evalScript(LuaScripts.promote, keys: keys, args: [id])
    }

    /// Pause the queue (sets meta.paused = "1"; workers respect this between fetches).
    func pause(queue: String) async throws {
        _ = try await client.evalScript(LuaScripts.pause,
            keys: [BullKeys.meta(prefix: prefix, queue: queue)],
            args: ["1"])
    }

    func resume(queue: String) async throws {
        _ = try await client.evalScript(LuaScripts.pause,
            keys: [BullKeys.meta(prefix: prefix, queue: queue)],
            args: ["0"])
    }

    /// Clean: bulk-remove the oldest N jobs in a given state.
    /// Returns the count actually removed.
    @discardableResult
    func clean(queue: String, state: JobState, limit: Int) async throws -> Int {
        let stateKey = BullKeys.list(prefix: prefix, queue: queue, state: state)
        let baseKey = BullKeys.base(prefix: prefix, queue: queue)
        let kind = state.storage == .list ? "list" : "zset"
        let reply = try await client.evalScript(LuaScripts.clean,
            keys: [stateKey, baseKey],
            args: [kind, limit])
        return Int(reply.intValue ?? 0)
    }

    /// Drain waiting + delayed + prioritized + paused.
    @discardableResult
    func drain(queue: String) async throws -> Int {
        var removed = 0
        for s in [JobState.waiting, .delayed, .prioritized, .paused] {
            removed += try await clean(queue: queue, state: s, limit: 100_000)
        }
        return removed
    }

    // MARK: Add job

    /// Insert a single job into `queue`. For `delay > 0` the job goes to the
    /// delayed zset; otherwise it goes to wait.
    @discardableResult
    func addJob(
        queue: String,
        name: String,
        data: String,
        priority: Int = 0,
        delayMs: Int64 = 0,
        attempts: Int = 1
    ) async throws -> String {
        let idKey = BullKeys.idCounter(prefix: prefix, queue: queue)
        let idReply = try await client.send("INCR", [idKey])
        guard let id = idReply.intValue else {
            throw RedisError.commandFailed("INCR returned non-integer for \(idKey)")
        }
        let jobID = String(id)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let hashKey = BullKeys.job(prefix: prefix, queue: queue, id: jobID)

        // BullMQ's job hash includes data, opts (json-encoded), name, timestamp,
        // attemptsMade, delay. opts gets a generated job id under the same name.
        let optsObj: [String: Any] = [
            "attempts": attempts,
            "delay": delayMs,
        ]
        let optsData = try JSONSerialization.data(withJSONObject: optsObj, options: [.sortedKeys])
        let optsString = String(data: optsData, encoding: .utf8) ?? "{}"

        var hsetArgs: [Any] = [hashKey]
        hsetArgs.append(contentsOf: [
            "name", name,
            "data", data.isEmpty ? "{}" : data,
            "opts", optsString,
            "timestamp", "\(now)",
            "delay", "\(delayMs)",
            "priority", "\(priority)",
            "attemptsMade", "0",
        ])

        var ops: [(String, [Any])] = [
            ("HSET", hsetArgs),
        ]
        if delayMs > 0 {
            // Delayed jobs are scored by their target run time (now + delay).
            let runAt = now + delayMs
            ops.append(("ZADD", [BullKeys.list(prefix: prefix, queue: queue, state: .delayed), runAt, jobID]))
        } else if priority > 0 {
            ops.append(("ZADD", [BullKeys.list(prefix: prefix, queue: queue, state: .prioritized), priority, jobID]))
        } else {
            ops.append(("LPUSH", [BullKeys.list(prefix: prefix, queue: queue, state: .waiting), jobID]))
        }
        // Emit a `waiting`/`delayed` event so dashboards using events streams see it.
        let event = delayMs > 0 ? "delayed" : "waiting"
        ops.append(("XADD", [
            BullKeys.eventsStream(prefix: prefix, queue: queue), "*",
            "event", event, "jobId", jobID,
        ]))
        _ = try await client.pipeline(ops)
        return jobID
    }

    // MARK: Schedulers

    /// List repeatable schedulers for a queue (sorted by next-run ascending).
    func listSchedulers(queue: String) async throws -> [BullScheduler] {
        let zkey = BullKeys.repeatZset(prefix: prefix, queue: queue)
        let reply = try await client.send("ZRANGE", [zkey, 0, -1, "WITHSCORES"])
        guard case .array(let arr?) = reply, !arr.isEmpty else { return [] }

        // arr is [id, score, id, score, …]
        var entries: [(id: String, score: Double)] = []
        var i = 0
        while i + 1 < arr.count {
            if let id = arr[i].stringValue, let scoreStr = arr[i + 1].stringValue, let score = Double(scoreStr) {
                entries.append((id, score))
            }
            i += 2
        }

        guard !entries.isEmpty else { return [] }
        let commands: [(String, [Any])] = entries.map { e in
            ("HGETALL", [BullKeys.scheduler(prefix: prefix, queue: queue, id: e.id)])
        }
        let replies = try await client.pipeline(commands)

        var out: [BullScheduler] = []
        out.reserveCapacity(entries.count)
        for (entry, reply) in zip(entries, replies) {
            var dict: [String: String] = [:]
            if case .array(let kv?) = reply {
                var j = 0
                while j + 1 < kv.count {
                    if let k = kv[j].stringValue, let v = kv[j + 1].stringValue {
                        dict[k] = v
                    }
                    j += 2
                }
            }
            let pattern = dict["pattern"]
            let every = (dict["every"]).flatMap { Int64($0) }
            let tz = dict["tz"]
            let endDate = (dict["endDate"]).flatMap { Int64($0) }
                .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            let limit = (dict["limit"]).flatMap { Int($0) }
            let nextRun = entry.score > 0 ? Date(timeIntervalSince1970: entry.score / 1000.0) : nil
            out.append(BullScheduler(
                id: entry.id,
                queueKey: "\(prefix):\(queue)",
                name: dict["name"],
                pattern: pattern,
                every: every,
                tz: tz,
                endDate: endDate,
                limit: limit,
                nextRun: nextRun
            ))
        }
        return out
    }

    /// Remove a repeatable scheduler. Does not retroactively delete already-emitted jobs.
    func removeScheduler(queue: String, id: String) async throws {
        _ = try await client.pipeline([
            ("ZREM", [BullKeys.repeatZset(prefix: prefix, queue: queue), id]),
            ("DEL", [BullKeys.scheduler(prefix: prefix, queue: queue, id: id)]),
        ])
    }

    // MARK: Workers

    /// Return connected BullMQ workers for `queue` by parsing CLIENT LIST.
    /// BullMQ workers `CLIENT SETNAME` to "<prefix>:<queue>:<role>:<uuid>".
    func listWorkers(queue: String) async throws -> [BullWorker] {
        let reply = try await client.send("CLIENT", ["LIST"])
        guard let raw = reply.stringValue else { return [] }
        let prefixMatch = "\(prefix):\(queue):"

        var out: [BullWorker] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var fields: [String: String] = [:]
            for kv in line.split(separator: " ", omittingEmptySubsequences: true) {
                if let eq = kv.firstIndex(of: "=") {
                    fields[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
                }
            }
            guard let name = fields["name"], name.hasPrefix(prefixMatch) else { continue }
            out.append(BullWorker(
                id: fields["id"] ?? "?",
                name: name,
                addr: fields["addr"] ?? "—",
                idleSeconds: Int(fields["idle"] ?? "") ?? 0,
                age: Int(fields["age"] ?? "") ?? 0
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: Flow / dependencies

    /// Children of a parent job: the unresolved dependencies set (waiting children).
    func unresolvedChildren(queue: String, id: String) async throws -> [String] {
        let reply = try await client.send("SMEMBERS", [BullKeys.dependencies(prefix: prefix, queue: queue, id: id)])
        if case .array(let arr?) = reply {
            return arr.compactMap { $0.stringValue }
        }
        return []
    }

    /// Resolved children: the `processed` hash keys are job-id refs that have returned.
    func resolvedChildren(queue: String, id: String) async throws -> [String] {
        let reply = try await client.send("HKEYS", [BullKeys.processed(prefix: prefix, queue: queue, id: id)])
        if case .array(let arr?) = reply {
            return arr.compactMap { $0.stringValue }
        }
        return []
    }

    /// Obliterate: wipe the entire queue.
    @discardableResult
    func obliterate(queue: String, force: Bool = false) async throws -> Bool {
        let reply = try await client.evalScript(LuaScripts.obliterate,
            keys: [BullKeys.base(prefix: prefix, queue: queue)],
            args: [force ? "1" : "0"])
        if reply.intValue == -1 {
            throw RedisError.commandFailed("Queue has active jobs. Use force.")
        }
        return reply.intValue == 1
    }
}
