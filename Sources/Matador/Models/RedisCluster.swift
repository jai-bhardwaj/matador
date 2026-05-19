import Foundation

/// Minimal Redis Cluster client. Maintains one `RedisClient` per master shard,
/// routes commands by CRC16 hash slot, and follows `MOVED` redirects.
///
/// BullMQ on Cluster requires `{queueName}` hash tags so every key for a queue
/// lands on the same shard. That makes pipelining and EVAL safe — we just
/// route the whole pipeline by the first command's first key.
actor RedisClusterClient: RedisCommandRunner {
    private let seeds: [(host: String, port: UInt16)]
    private let tls: Bool
    private let username: String?
    private let password: String?
    private let database: Int

    /// All known master nodes, keyed by "host:port".
    private var masters: [String: RedisClient] = [:]
    /// Slot start (inclusive) → "host:port" of master serving that slot range.
    /// Ranges are sorted by start; lookup is a binary search.
    private var slotMap: [(start: UInt16, end: UInt16, key: String)] = []

    init(seeds: [(String, UInt16)], tls: Bool, username: String?, password: String?, database: Int) {
        self.seeds = seeds
        self.tls = tls
        self.username = (username?.isEmpty ?? true) ? nil : username
        self.password = (password?.isEmpty ?? true) ? nil : password
        self.database = database
    }

    // MARK: Lifecycle

    func connect() async throws {
        // Connect to a seed, get topology, build masters.
        var lastError: Error?
        for seed in seeds {
            do {
                try await refreshTopology(seedHost: seed.host, seedPort: seed.port)
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw RedisError.connectionFailed("no cluster seed reachable: \(lastError?.localizedDescription ?? "unknown")")
    }

    func disconnect() async {
        for (_, c) in masters { await c.disconnect() }
        masters.removeAll()
        slotMap.removeAll()
    }

    private func refreshTopology(seedHost: String, seedPort: UInt16) async throws {
        let seed = RedisClient(
            host: seedHost, port: seedPort, tls: tls,
            username: username, password: password, database: 0
        )
        try await seed.connect()
        defer { Task { await seed.disconnect() } }

        let reply = try await seed.send("CLUSTER", ["SLOTS"])
        guard case .array(let rows?) = reply else {
            throw RedisError.unexpectedReply("CLUSTER SLOTS")
        }

        var newMap: [(UInt16, UInt16, String)] = []
        var seenKeys = Set<String>()

        for row in rows {
            guard case .array(let cells?) = row, cells.count >= 3,
                  let start = cells[0].intValue,
                  let end = cells[1].intValue,
                  case .array(let master?) = cells[2], master.count >= 2,
                  let host = master[0].stringValue,
                  let port = master[1].intValue
            else { continue }
            let key = "\(host):\(port)"
            newMap.append((UInt16(start), UInt16(end), key))
            seenKeys.insert(key)
        }

        // Open clients for new masters; tear down clients for nodes no longer present.
        for key in masters.keys where !seenKeys.contains(key) {
            await masters[key]?.disconnect()
            masters.removeValue(forKey: key)
        }
        for (_, _, key) in newMap where masters[key] == nil {
            let parts = key.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
            let c = RedisClient(
                host: String(parts[0]), port: port, tls: tls,
                username: username, password: password, database: database
            )
            try? await c.connect()
            masters[key] = c
        }

        newMap.sort { $0.0 < $1.0 }
        slotMap = newMap
    }

    // MARK: Routing

    private func nodeKey(forSlot slot: UInt16) -> String? {
        // Linear scan is fine — ~16 entries on a typical small cluster.
        for r in slotMap {
            if slot >= r.start && slot <= r.end { return r.key }
        }
        return nil
    }

    /// Extract the key used for routing from a command's args.
    /// Returns nil for keyless commands (PING, INFO, CLUSTER, etc).
    private func routingKey(forCommand cmd: String, args: [Any]) -> String? {
        let upper = cmd.uppercased()
        switch upper {
        case "EVAL", "EVALSHA":
            // args = [script, numKeys, key1, key2, ..., arg1, arg2, ...]
            guard args.count >= 3, let n = (args[1] as? Int).flatMap({ $0 }) ?? Int(String(describing: args[1])) else { return nil }
            if n == 0 { return nil }
            return String(describing: args[2])
        case "PING", "INFO", "CLUSTER", "SCAN", "FLUSHDB", "FLUSHALL", "TIME", "DBSIZE":
            return nil
        default:
            // Default: first arg is the key
            return args.first.map { String(describing: $0) }
        }
    }

    private func nodeForCommand(_ cmd: String, args: [Any]) -> RedisClient? {
        guard let key = routingKey(forCommand: cmd, args: args) else {
            // Keyless: send to any master
            return masters.values.first
        }
        let slot = RedisCRC16.slot(forKey: key)
        guard let nodeKey = nodeKey(forSlot: slot) else { return masters.values.first }
        return masters[nodeKey]
    }

    // MARK: Commands

    func send(_ command: String, _ args: [Any]) async throws -> RESPValue {
        guard let node = nodeForCommand(command, args: args) else {
            throw RedisError.notConnected
        }
        let reply = try await node.send(command, args)
        return try await followRedirect(reply: reply, command: command, args: args)
    }

    func pipeline(_ commands: [(String, [Any])]) async throws -> [RESPValue] {
        guard let first = commands.first else { return [] }
        guard let node = nodeForCommand(first.0, args: first.1) else {
            throw RedisError.notConnected
        }
        let replies = try await node.pipeline(commands)
        // For pipelines we don't follow MOVED — BullMQ pipelines are all
        // hash-tagged to one shard, so MOVED would only happen mid-resharding.
        // If we hit one, return the error reply as-is; the caller will see it.
        return replies
    }

    func scanAll(matching pattern: String) async throws -> [String] {
        // SCAN every master and merge keys.
        var keys: [String] = []
        for (_, node) in masters {
            keys.append(contentsOf: try await node.scanAll(matching: pattern))
        }
        return keys
    }

    // MARK: MOVED / ASK

    private func followRedirect(reply: RESPValue, command: String, args: [Any]) async throws -> RESPValue {
        guard case .error(let msg) = reply else { return reply }
        if msg.hasPrefix("MOVED ") {
            // MOVED <slot> <host>:<port>
            let parts = msg.split(separator: " ")
            guard parts.count == 3 else { return reply }
            let target = String(parts[2])
            // Make sure we have a client for that node
            if masters[target] == nil {
                if let (host, port) = HostPort.parse(target, fallback: 6379).map({ ($0.host, $0.port) }) {
                    let c = RedisClient(
                        host: host, port: port, tls: tls,
                        username: username, password: password, database: database
                    )
                    try? await c.connect()
                    masters[target] = c
                }
            }
            // Refresh topology in background — slot map is now stale.
            if let firstSeed = seeds.first {
                Task { try? await self.refreshTopology(seedHost: firstSeed.host, seedPort: firstSeed.port) }
            }
            if let node = masters[target] {
                return try await node.send(command, args)
            }
            return reply
        }
        if msg.hasPrefix("ASK ") {
            // ASK <slot> <host>:<port> — one-shot redirect, must send ASKING first
            let parts = msg.split(separator: " ")
            guard parts.count == 3 else { return reply }
            let target = String(parts[2])
            if masters[target] == nil,
               let (host, port) = HostPort.parse(target, fallback: 6379).map({ ($0.host, $0.port) }) {
                let c = RedisClient(
                    host: host, port: port, tls: tls,
                    username: username, password: password, database: database
                )
                try? await c.connect()
                masters[target] = c
            }
            if let node = masters[target] {
                _ = try await node.send("ASKING", [])
                return try await node.send(command, args)
            }
        }
        return reply
    }
}
