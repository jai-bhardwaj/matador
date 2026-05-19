import Foundation

/// What BullMQService and EVAL talk to. Both standalone RedisClient and
/// RedisClusterClient conform.
protocol RedisCommandRunner: Sendable {
    func send(_ command: String, _ args: [Any]) async throws -> RESPValue
    func pipeline(_ commands: [(String, [Any])]) async throws -> [RESPValue]
    /// SCAN over all relevant nodes (one for standalone; every master for cluster).
    func scanAll(matching pattern: String) async throws -> [String]
    func disconnect() async
}

// MARK: - Default scanAll for single-node runners

extension RedisCommandRunner {
    func scanAllOnSingleNode(matching pattern: String) async throws -> [String] {
        var cursor = "0"
        var keys: [String] = []
        repeat {
            let reply = try await send("SCAN", [cursor, "MATCH", pattern, "COUNT", 500])
            guard case .array(let arr?) = reply,
                  arr.count == 2,
                  let next = arr[0].stringValue,
                  case .array(let chunk?) = arr[1] else {
                throw RedisError.unexpectedReply("SCAN")
            }
            cursor = next
            for k in chunk {
                if let s = k.stringValue { keys.append(s) }
            }
        } while cursor != "0"
        return keys
    }
}

extension RedisClient: RedisCommandRunner {
    func scanAll(matching pattern: String) async throws -> [String] {
        try await scanAllOnSingleNode(matching: pattern)
    }
}

// MARK: - EVAL on any runner

extension RedisCommandRunner {
    func evalScript(_ script: LuaScript, keys: [String], args: [Any]) async throws -> RESPValue {
        let argv: [Any] = [script.sha1, keys.count] + keys + args
        let reply = try await send("EVALSHA", argv)
        if case .error(let msg) = reply, msg.hasPrefix("NOSCRIPT") {
            let argvEval: [Any] = [script.body, keys.count] + keys + args
            return try await send("EVAL", argvEval)
        }
        return reply
    }
}
