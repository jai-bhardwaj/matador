import Foundation

/// Minimal cron expression parser supporting the standard 5-field syntax:
///   minute hour day-of-month month day-of-week
///
/// Each field accepts: a single value, comma list, `*`, `*/N`, `A-B`, `A-B/N`.
/// Day-of-week: 0=Sun..6=Sat (also accepts 7=Sun).
/// Computes the next fire times after a given date.
struct CronExpression {
    let minute: Set<Int>      // 0..59
    let hour: Set<Int>        // 0..23
    let dayOfMonth: Set<Int>  // 1..31
    let month: Set<Int>       // 1..12
    let dayOfWeek: Set<Int>   // 0..6

    init?(_ raw: String) {
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5 else { return nil }
        guard let m = Self.parseField(parts[0], range: 0...59),
              let h = Self.parseField(parts[1], range: 0...23),
              let d = Self.parseField(parts[2], range: 1...31),
              let mo = Self.parseField(parts[3], range: 1...12),
              let dw0 = Self.parseField(parts[4], range: 0...7)
        else { return nil }
        // Normalize 7 → 0 for day-of-week
        var dw = dw0
        if dw.contains(7) { dw.remove(7); dw.insert(0) }
        self.minute = m
        self.hour = h
        self.dayOfMonth = d
        self.month = mo
        self.dayOfWeek = dw
    }

    private static func parseField(_ field: String, range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: true) {
            var step = 1
            var base = String(part)
            if let slash = base.firstIndex(of: "/") {
                guard let s = Int(base[base.index(after: slash)...]), s >= 1 else { return nil }
                step = s
                base = String(base[..<slash])
            }
            let lo: Int
            let hi: Int
            if base == "*" {
                lo = range.lowerBound
                hi = range.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                guard let a = Int(base[..<dash]),
                      let b = Int(base[base.index(after: dash)...]) else { return nil }
                lo = a; hi = b
            } else {
                guard let n = Int(base) else { return nil }
                lo = n; hi = n
            }
            guard lo >= range.lowerBound, hi <= range.upperBound, lo <= hi else { return nil }
            for v in stride(from: lo, through: hi, by: step) { out.insert(v) }
        }
        return out.isEmpty ? nil : out
    }

    /// Compute the next `count` fire dates strictly after `from`, in the given
    /// time zone. Caps iteration to avoid worst-case forever loops.
    func nextFires(after from: Date, in tz: TimeZone = .current, count: Int = 5) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var results: [Date] = []

        // Walk forward minute by minute up to 4 years ahead.
        var candidate = cal.date(byAdding: .minute, value: 1, to: from) ?? from
        candidate = cal.date(bySetting: .second, value: 0, of: candidate) ?? candidate
        let limit = cal.date(byAdding: .year, value: 4, to: from) ?? from

        while results.count < count, candidate < limit {
            let comps = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            // Calendar weekday: 1=Sun..7=Sat → map to 0=Sun..6=Sat
            let dow = ((comps.weekday ?? 1) - 1 + 7) % 7
            if let m = comps.minute, minute.contains(m),
               let h = comps.hour, hour.contains(h),
               let d = comps.day, dayOfMonth.contains(d),
               let mo = comps.month, month.contains(mo),
               dayOfWeek.contains(dow) {
                results.append(candidate)
            }
            candidate = cal.date(byAdding: .minute, value: 1, to: candidate) ?? candidate.addingTimeInterval(60)
        }
        return results
    }
}
