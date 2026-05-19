import Foundation
import CryptoKit

/// Embedded Lua scripts loaded from the bundle.
/// First execution does EVAL; subsequent calls use EVALSHA for round-trip savings.
struct LuaScript {
    let name: String
    let body: String
    let sha1: String

    init(name: String, body: String) {
        self.name = name
        self.body = body
        let digest = Insecure.SHA1.hash(data: body.data(using: .utf8) ?? Data())
        self.sha1 = digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LuaScripts {
    static let retry      = load("retry")
    static let promote    = load("promote")
    static let removeJob  = load("removeJob")
    static let pause      = load("pause")
    static let clean      = load("clean")
    static let obliterate = load("obliterate")

    private static func load(_ name: String) -> LuaScript {
        if let url = Bundle.module.url(forResource: name, withExtension: "lua", subdirectory: "lua"),
           let body = try? String(contentsOf: url, encoding: .utf8) {
            return LuaScript(name: name, body: body)
        }
        // Fallback: subdir not retained in bundle layout
        if let url = Bundle.module.url(forResource: name, withExtension: "lua"),
           let body = try? String(contentsOf: url, encoding: .utf8) {
            return LuaScript(name: name, body: body)
        }
        fatalError("Lua script '\(name).lua' missing from bundle resources")
    }
}

// evalScript is defined as an extension on RedisCommandRunner — see RedisRunner.swift
