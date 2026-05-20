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

enum TLSMode: String, Codable, CaseIterable, Hashable {
    case off
    case on
    case auto

    var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return "Auto"
        }
    }

    var help: String {
        switch self {
        case .off: return "Plain TCP (redis://)"
        case .on: return "Always TLS (rediss://)"
        case .auto: return "Try plain TCP first, fall back to TLS if the server appears TLS-only"
        }
    }
}

/// A saved Redis connection profile. Passwords live in macOS Keychain, not here.
struct RedisProfile: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var mode: ConnectionMode

    // Standalone
    var host: String
    var port: Int

    // Sentinel
    var sentinelHosts: [String]
    var sentinelMasterName: String
    // Cluster
    var clusterSeeds: [String]

    var username: String
    var database: Int
    var tlsMode: TLSMode
    var bullPrefix: String
    var savePassword: Bool

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
        tlsMode: TLSMode = .auto,
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
        self.tlsMode = tlsMode
        self.bullPrefix = bullPrefix
        self.savePassword = savePassword
    }

    var summary: String {
        let scheme: String
        switch tlsMode {
        case .on:   scheme = "rediss"
        case .off:  scheme = "redis"
        case .auto: scheme = "redis"  // resolved at connect time
        }
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

    // Backward-compat: older profile files used `tls: Bool` instead of `tlsMode`.
    enum CodingKeys: String, CodingKey {
        case id, name, mode, host, port
        case sentinelHosts, sentinelMasterName, clusterSeeds
        case username, database, tls, tlsMode, bullPrefix, savePassword
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
        if let mode = try? c.decode(TLSMode.self, forKey: .tlsMode) {
            tlsMode = mode
        } else {
            let oldBool = (try? c.decode(Bool.self, forKey: .tls)) ?? false
            tlsMode = oldBool ? .on : .auto
        }
        bullPrefix = (try? c.decode(String.self, forKey: .bullPrefix)) ?? "bull"
        savePassword = (try? c.decode(Bool.self, forKey: .savePassword)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(mode, forKey: .mode)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(sentinelHosts, forKey: .sentinelHosts)
        try c.encode(sentinelMasterName, forKey: .sentinelMasterName)
        try c.encode(clusterSeeds, forKey: .clusterSeeds)
        try c.encode(username, forKey: .username)
        try c.encode(database, forKey: .database)
        try c.encode(tlsMode, forKey: .tlsMode)
        try c.encode(bullPrefix, forKey: .bullPrefix)
        try c.encode(savePassword, forKey: .savePassword)
        // Note: legacy `tls` Bool is decode-only — we don't write it back so
        // newly-saved profiles use the canonical tlsMode field.
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

// MARK: - Redis URL parsing
//
// Accepts the standard form used by every Redis client / cloud provider:
//   redis://[username:password@]host[:port][/db]
//   rediss://[username:password@]host[:port][/db]

struct RedisURLParts: Equatable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let database: Int
    let tlsMode: TLSMode
}

enum RedisURL {
    static func parse(_ raw: String) -> RedisURLParts? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "redis" || scheme == "rediss"),
              let host = url.host, !host.isEmpty
        else { return nil }

        let port = url.port ?? 6379
        let username = url.user(percentEncoded: false) ?? ""
        let password = url.password(percentEncoded: false) ?? ""
        let dbString = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let database = Int(dbString) ?? 0
        return RedisURLParts(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tlsMode: scheme == "rediss" ? .on : .off
        )
    }
}
