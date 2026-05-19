import Foundation

/// Redis Cluster's CRC16/XMODEM with hash-tag support.
enum RedisCRC16 {
    private static let table: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc: UInt16 = UInt16(i) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
            t[i] = crc
        }
        return t
    }()

    static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in data {
            let idx = Int(UInt8(truncatingIfNeeded: crc >> 8) ^ b)
            crc = (crc << 8) ^ table[idx]
        }
        return crc
    }

    /// Compute the slot (0..16383) for a key, honouring `{tag}` hash tags.
    static func slot(forKey key: String) -> UInt16 {
        let bytes = Array(key.utf8)
        if let open = bytes.firstIndex(of: 0x7B) { // {
            let after = bytes.index(after: open)
            if after < bytes.endIndex,
               let close = bytes[after...].firstIndex(of: 0x7D), close > after {
                let tag = Array(bytes[after..<close])
                return crc16(tag) & 16383
            }
        }
        return crc16(bytes) & 16383
    }
}
