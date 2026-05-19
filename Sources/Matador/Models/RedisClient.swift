import Foundation
import Network

enum RedisError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case commandFailed(String)
    case unexpectedReply(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Redis: not connected"
        case .connectionFailed(let m): return "Redis: \(m)"
        case .commandFailed(let m): return m
        case .unexpectedReply(let m): return "Redis: unexpected reply (\(m))"
        case .timeout: return "Redis: timed out"
        }
    }
}

/// What endpoint to talk to.
enum ConnectionTarget: Sendable {
    case standalone(host: String, port: UInt16)
    case sentinel(sentinels: [(host: String, port: UInt16)],
                  masterName: String,
                  sentinelPassword: String?)
}

/// Minimal async/await Redis client over Apple's Network framework.
/// Supports plain TCP + TLS (rediss://), AUTH (optional user), SELECT,
/// pipelining, and Sentinel master discovery.
actor RedisClient {
    private let target: ConnectionTarget
    private let useTLS: Bool
    private let password: String?
    private let username: String?
    private let database: Int

    private(set) var resolvedHost: String = ""
    private(set) var resolvedPort: UInt16 = 0

    private var connection: NWConnection?
    private let parser = RESPParser()
    private var pendingReplies: [PendingReply] = []
    private var receiveTask: Task<Void, Never>?

    /// Standalone init (back-compat with single-host usage).
    init(host: String, port: UInt16, tls: Bool, username: String?, password: String?, database: Int) {
        self.target = .standalone(host: host, port: port)
        self.useTLS = tls
        self.username = username
        self.password = (password?.isEmpty ?? true) ? nil : password
        self.database = database
    }

    /// Init with an explicit target (standalone or sentinel).
    init(target: ConnectionTarget, tls: Bool, username: String?, password: String?, database: Int) {
        self.target = target
        self.useTLS = tls
        self.username = username
        self.password = (password?.isEmpty ?? true) ? nil : password
        self.database = database
    }

    // MARK: - Lifecycle

    func connect() async throws {
        if let c = connection, c.state == .ready { return }
        await tearDown()

        let (host, port) = try await resolveTarget()
        self.resolvedHost = host
        self.resolvedPort = port

        try await openConnection(host: host, port: port)
        startReceiveLoop()
        try await authenticate()

        if database != 0 {
            let r = try await send("SELECT", [database])
            if case .error(let m) = r { throw RedisError.commandFailed(m) }
        }

        let pong = try await send("PING")
        if case .error(let m) = pong { throw RedisError.commandFailed(m) }
    }

    /// Resolve the actual host/port to dial. For Sentinel, this opens a short-
    /// lived connection to each sentinel and asks for the master address.
    private func resolveTarget() async throws -> (String, UInt16) {
        switch target {
        case .standalone(let h, let p):
            return (h, p)
        case .sentinel(let sentinels, let masterName, let sentinelPassword):
            var lastError: Error?
            for sentinel in sentinels {
                do {
                    let (host, port) = try await querySentinel(
                        host: sentinel.host, port: sentinel.port,
                        masterName: masterName, password: sentinelPassword
                    )
                    return (host, port)
                } catch {
                    lastError = error
                    continue
                }
            }
            throw RedisError.connectionFailed(
                "no sentinel resolved master '\(masterName)': \(lastError?.localizedDescription ?? "unknown")"
            )
        }
    }

    /// Open one short-lived RESP connection to a sentinel and ask for the master.
    private func querySentinel(host: String, port: UInt16, masterName: String, password: String?) async throws -> (String, UInt16) {
        let sentinel = RedisClient(
            host: host, port: port, tls: false,
            username: nil, password: password, database: 0
        )
        try await sentinel.connect()
        defer { Task { await sentinel.disconnect() } }

        let reply = try await sentinel.send("SENTINEL", ["get-master-addr-by-name", masterName])
        guard case .array(let arr?) = reply, arr.count == 2,
              let masterHost = arr[0].stringValue,
              let portStr = arr[1].stringValue,
              let masterPort = UInt16(portStr)
        else {
            throw RedisError.commandFailed("Sentinel \(host):\(port) returned no master for '\(masterName)'")
        }
        return (masterHost, masterPort)
    }

    private func openConnection(host: String, port: UInt16) async throws {
        let params: NWParameters = useTLS
            ? NWParameters(tls: .init(), tcp: .init())
            : NWParameters.tcp
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 6379)
        )
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        let resumed = AtomicFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setIfUnset() { cont.resume() }
                case .failed(let err):
                    if resumed.setIfUnset() {
                        cont.resume(throwing: RedisError.connectionFailed(err.localizedDescription))
                    }
                case .cancelled:
                    if resumed.setIfUnset() {
                        cont.resume(throwing: RedisError.connectionFailed("cancelled"))
                    }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private func authenticate() async throws {
        guard let pw = password else { return }
        let reply: RESPValue
        if let user = username, !user.isEmpty {
            reply = try await send("AUTH", [user, pw])
        } else {
            reply = try await send("AUTH", [pw])
        }
        if case .error(let m) = reply {
            throw RedisError.commandFailed(m)
        }
    }

    func disconnect() async {
        await tearDown()
    }

    private func tearDown() async {
        for p in pendingReplies {
            p.deliver(.failure(RedisError.notConnected))
        }
        pendingReplies.removeAll()
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: - Commands

    @discardableResult
    func send(_ command: String, _ args: [Any] = []) async throws -> RESPValue {
        let results = try await pipeline([(command, args)])
        return results[0]
    }

    @discardableResult
    func pipeline(_ commands: [(String, [Any])]) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        guard let conn = connection, conn.state == .ready else {
            throw RedisError.notConnected
        }

        var payload = Data()
        for (c, a) in commands {
            payload.append(RESPEncoder.encode(c, a))
        }

        // Register reply slots BEFORE writing so the receive loop can match.
        var slots: [PendingReply] = []
        slots.reserveCapacity(commands.count)
        for _ in 0..<commands.count {
            slots.append(PendingReply())
        }
        pendingReplies.append(contentsOf: slots)

        // Write
        conn.send(content: payload, completion: .contentProcessed { err in
            if let err = err {
                // Caller awaits below; if write fails, fail all matching slots.
                for s in slots { s.deliver(.failure(RedisError.connectionFailed(err.localizedDescription))) }
            }
        })

        // Collect in order
        var out: [RESPValue] = []
        out.reserveCapacity(slots.count)
        for s in slots {
            out.append(try await s.wait())
        }
        return out
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task.detached { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let conn = self.connection else { return }
            let chunk: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
                    if err != nil || isComplete {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: data)
                    }
                }
            }
            guard let data = chunk, !data.isEmpty else {
                self.handleEOF()
                return
            }
            self.ingest(data)
        }
    }

    private func handleEOF() {
        for p in pendingReplies {
            p.deliver(.failure(RedisError.notConnected))
        }
        pendingReplies.removeAll()
        connection?.cancel()
        connection = nil
        receiveTask = nil
    }

    private func ingest(_ data: Data) {
        parser.feed(data)
        while let v = parser.nextValue() {
            guard !pendingReplies.isEmpty else { continue }
            let p = pendingReplies.removeFirst()
            p.deliver(.success(v))
        }
    }
}

// MARK: - PendingReply
//
// Bridges between the receive loop (which delivers a value) and the caller
// (which awaits one). Either side may arrive first.

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    /// Returns true if this call set the flag (i.e. it was previously unset).
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<RESPValue, Error>?
    private var continuation: CheckedContinuation<RESPValue, Error>?

    func deliver(_ r: Result<RESPValue, Error>) {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            switch r {
            case .success(let v): c.resume(returning: v)
            case .failure(let e): c.resume(throwing: e)
            }
        } else if result == nil {
            result = r
            lock.unlock()
        } else {
            lock.unlock()
        }
    }

    func wait() async throws -> RESPValue {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let r = result {
                result = nil
                lock.unlock()
                switch r {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}
