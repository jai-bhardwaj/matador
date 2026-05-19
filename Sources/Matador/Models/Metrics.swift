import Foundation

/// A single point-in-time snapshot of one queue's counts.
struct QueueSample: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let counts: [JobState: Int]
    let stalled: Int
    let workers: Int

    func count(_ s: JobState) -> Int { counts[s] ?? 0 }
}

/// A small derived measurement between two adjacent samples.
struct QueueRate: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let completedDelta: Int  // jobs completed since prev sample (per second)
    let failedDelta: Int     // jobs failed since prev sample (per second)
}

/// Rolling window of samples per queue (id = "<prefix>:<name>").
@MainActor
final class MetricsStore {
    static let shared = MetricsStore()

    /// How many samples to retain — at 5s/sample that's ~30 minutes.
    private let maxSamples = 360
    private(set) var samples: [String: [QueueSample]] = [:]

    func record(queueID: String, sample: QueueSample) {
        var arr = samples[queueID] ?? []
        arr.append(sample)
        if arr.count > maxSamples {
            arr.removeFirst(arr.count - maxSamples)
        }
        samples[queueID] = arr
    }

    func reset(queueID: String) {
        samples.removeValue(forKey: queueID)
    }

    func samples(for queueID: String) -> [QueueSample] {
        samples[queueID] ?? []
    }

    /// Derive completed/failed per-second rates from adjacent samples.
    func rates(for queueID: String) -> [QueueRate] {
        let s = samples(for: queueID)
        guard s.count > 1 else { return [] }
        var out: [QueueRate] = []
        for i in 1..<s.count {
            let prev = s[i - 1]
            let cur = s[i]
            let dt = max(cur.timestamp.timeIntervalSince(prev.timestamp), 0.001)
            let completed = max(0, cur.count(.completed) - prev.count(.completed))
            let failed = max(0, cur.count(.failed) - prev.count(.failed))
            // Normalise to per-second
            out.append(QueueRate(
                timestamp: cur.timestamp,
                completedDelta: Int(Double(completed) / dt * 1.0),
                failedDelta: Int(Double(failed) / dt * 1.0)
            ))
        }
        return out
    }
}
