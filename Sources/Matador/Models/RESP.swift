import Foundation

// MARK: - RESP2 value

enum RESPValue: Equatable {
    case simpleString(String)
    case error(String)
    case integer(Int64)
    case bulkString(Data?)   // nil = $-1 (null bulk)
    case array([RESPValue]?) // nil = *-1 (null array)

    var stringValue: String? {
        switch self {
        case .simpleString(let s): return s
        case .bulkString(let d): return d.flatMap { String(data: $0, encoding: .utf8) }
        case .integer(let i): return String(i)
        default: return nil
        }
    }

    var intValue: Int64? {
        switch self {
        case .integer(let i): return i
        case .bulkString(let d): return d.flatMap { String(data: $0, encoding: .utf8) }.flatMap { Int64($0) }
        case .simpleString(let s): return Int64(s)
        default: return nil
        }
    }

    var arrayValue: [RESPValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var errorMessage: String? {
        if case .error(let s) = self { return s }
        return nil
    }
}

// MARK: - Encoder

enum RESPEncoder {
    /// Encode a command + arguments as a RESP2 array of bulk strings.
    /// Args may be String, Int, Int64, Double, or Data.
    static func encode(_ command: String, _ args: [Any] = []) -> Data {
        var out = Data()
        out.append("*\(args.count + 1)\r\n".data(using: .ascii)!)
        appendBulk(command.data(using: .utf8)!, to: &out)
        for a in args {
            appendBulk(bulkData(a), to: &out)
        }
        return out
    }

    private static func bulkData(_ a: Any) -> Data {
        switch a {
        case let s as String: return s.data(using: .utf8) ?? Data()
        case let i as Int: return String(i).data(using: .ascii)!
        case let i as Int64: return String(i).data(using: .ascii)!
        case let d as Double: return String(d).data(using: .ascii)!
        case let d as Data: return d
        case let b as Bool: return (b ? "1" : "0").data(using: .ascii)!
        default: return String(describing: a).data(using: .utf8) ?? Data()
        }
    }

    private static func appendBulk(_ data: Data, to out: inout Data) {
        out.append("$\(data.count)\r\n".data(using: .ascii)!)
        out.append(data)
        out.append("\r\n".data(using: .ascii)!)
    }
}

// MARK: - Parser

/// Stateful RESP parser that accumulates bytes and yields complete values.
///
/// Uses `[UInt8]` (not `Data`) as the buffer: Swift's `Data` does not
/// guarantee `startIndex == 0` after `removeFirst(_:)`, which makes 0-based
/// subscripts inside the parser unsafe. Array doesn't have that problem.
final class RESPParser {
    private var buffer: [UInt8] = []

    func feed(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Returns the next complete RESP value, or nil if more data is needed.
    /// Consumes the bytes for the returned value from the buffer.
    func nextValue() -> RESPValue? {
        var idx = 0
        guard let v = try? parse(at: &idx) else { return nil }
        if idx > 0 { buffer.removeFirst(idx) }
        return v
    }

    private struct NeedMore: Error {}

    private func parse(at idx: inout Int) throws -> RESPValue {
        guard idx < buffer.count else { throw NeedMore() }
        let marker = buffer[idx]
        idx += 1
        switch marker {
        case UInt8(ascii: "+"):
            return .simpleString(try readLine(at: &idx))
        case UInt8(ascii: "-"):
            return .error(try readLine(at: &idx))
        case UInt8(ascii: ":"):
            let s = try readLine(at: &idx)
            return .integer(Int64(s) ?? 0)
        case UInt8(ascii: "$"):
            let len = Int(try readLine(at: &idx)) ?? -1
            if len < 0 { return .bulkString(nil) }
            // Need: len payload bytes + trailing \r\n
            guard idx + len + 2 <= buffer.count else { throw NeedMore() }
            let payload = Data(buffer[idx..<(idx + len)])
            idx += len
            guard buffer[idx] == 0x0D, buffer[idx + 1] == 0x0A else {
                throw NeedMore()
            }
            idx += 2
            return .bulkString(payload)
        case UInt8(ascii: "*"):
            let count = Int(try readLine(at: &idx)) ?? -1
            if count < 0 { return .array(nil) }
            var arr: [RESPValue] = []
            arr.reserveCapacity(count)
            for _ in 0..<count {
                arr.append(try parse(at: &idx))
            }
            return .array(arr)
        default:
            // Unknown marker — treat as protocol error
            return .error("protocol: unknown marker \(marker)")
        }
    }

    /// Reads up to (but not including) the next \r\n and advances idx past it.
    private func readLine(at idx: inout Int) throws -> String {
        var end = idx
        while end + 1 < buffer.count {
            if buffer[end] == 0x0D, buffer[end + 1] == 0x0A {
                let s = String(decoding: buffer[idx..<end], as: UTF8.self)
                idx = end + 2
                return s
            }
            end += 1
        }
        throw NeedMore()
    }
}
