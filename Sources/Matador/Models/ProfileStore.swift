import Foundation

/// Persists the user's Redis profiles to
/// `~/Library/Application Support/Matador/profiles.json`.
struct ProfileStore {
    static let shared = ProfileStore()

    private let fileURL: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Matador", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("profiles.json")
    }

    func load() -> [RedisProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let profiles = try? JSONDecoder().decode([RedisProfile].self, from: data)
        else { return [] }
        return profiles
    }

    func save(_ profiles: [RedisProfile]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// Last-used profile id, persisted separately for quick boot.
    private var lastUsedURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("last.json")
    }

    func loadLastUsed() -> UUID? {
        guard let data = try? Data(contentsOf: lastUsedURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let s = obj["id"], let uuid = UUID(uuidString: s)
        else { return nil }
        return uuid
    }

    func saveLastUsed(_ id: UUID?) {
        if let id = id {
            let obj = ["id": id.uuidString]
            if let data = try? JSONSerialization.data(withJSONObject: obj) {
                try? data.write(to: lastUsedURL, options: [.atomic])
            }
        } else {
            try? FileManager.default.removeItem(at: lastUsedURL)
        }
    }
}
