import Foundation

enum ConnectionMode: String, Codable, CaseIterable, Hashable {
    case standalone
    case sentinel
    case cluster

    var label: String {
        switch self {
        case .standalone: return "Standalone"
        case .sentinel: return "Sentinel"
        case .cluster: return "Cluster"
        }
    }
}

/// A saved Redis connection profile. Passwords are stored separately in the
/// macOS Keychain — only the profile id is referenced here so the on-disk JSON
/// never contains credentials.
struct RedisProfile: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var mode: ConnectionMode

    // Standalone
    var host: String
    var port: Int

    // Sentinel
    var sentinelHosts: [String]   // "host:port" strings; min 1 entry
    var sentinelMasterName: String
    // Cluster
    var clusterSeeds: [String]    // "host:port" strings; min 1 entry

    var username: String          // for Redis ACL; "" for legacy AUTH
    var database: Int
    var tls: Bool
    var bullPrefix: String        // default "bull"
    var savePassword: Bool        // if false, prompt every connect

    init(
        id: UUID = UUID(),
        name: String = "Local",
        mode: ConnectionMode = .standalone,
        host: String = "127.0.0.1",
        port: Int = 6379,
        sentinelHosts: [String] = [],
        sentinelMasterName: String = "mymaster",
        clusterSeeds: [String] = [],
        username: String = "",
        database: Int = 0,
        tls: Bool = false,
        bullPrefix: String = "bull",
        savePassword: Bool = true
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.host = host
        self.port = port
        self.sentinelHosts = sentinelHosts
        self.sentinelMasterName = sentinelMasterName
        self.clusterSeeds = clusterSeeds
        self.username = username
        self.database = database
        self.tls = tls
        self.bullPrefix = bullPrefix
        self.savePassword = savePassword
    }

    var summary: String {
        let scheme = tls ? "rediss" : "redis"
        let userPart = username.isEmpty ? "" : "\(username)@"
        switch mode {
        case .standalone:
            return "\(scheme)://\(userPart)\(host):\(port)/\(database)"
        case .sentinel:
            let s = sentinelHosts.first ?? "?"
            return "sentinel://\(s)/\(sentinelMasterName)"
        case .cluster:
            let s = clusterSeeds.first ?? "?"
            return "cluster://\(s)"
        }
    }

    /// Decoder with sane defaults so older profile files (pre-mode field) still load.
    enum CodingKeys: String, CodingKey {
        case id, name, mode, host, port
        case sentinelHosts, sentinelMasterName, clusterSeeds
        case username, database, tls, bullPrefix, savePassword
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mode = (try? c.decode(ConnectionMode.self, forKey: .mode)) ?? .standalone
        host = (try? c.decode(String.self, forKey: .host)) ?? "127.0.0.1"
        port = (try? c.decode(Int.self, forKey: .port)) ?? 6379
        sentinelHosts = (try? c.decode([String].self, forKey: .sentinelHosts)) ?? []
        sentinelMasterName = (try? c.decode(String.self, forKey: .sentinelMasterName)) ?? "mymaster"
        clusterSeeds = (try? c.decode([String].self, forKey: .clusterSeeds)) ?? []
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        database = (try? c.decode(Int.self, forKey: .database)) ?? 0
        tls = (try? c.decode(Bool.self, forKey: .tls)) ?? false
        bullPrefix = (try? c.decode(String.self, forKey: .bullPrefix)) ?? "bull"
        savePassword = (try? c.decode(Bool.self, forKey: .savePassword)) ?? true
    }
}

// MARK: - Helpers

enum HostPort {
    /// Parse "host:port" or "host" (port defaults to fallback).
    static func parse(_ s: String, fallback port: UInt16 = 26379) -> (host: String, port: UInt16)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let colon = t.lastIndex(of: ":") {
            let host = String(t[..<colon])
            let portStr = String(t[t.index(after: colon)...])
            if let p = UInt16(portStr) { return (host, p) }
            return nil
        }
        return (t, port)
    }
}
