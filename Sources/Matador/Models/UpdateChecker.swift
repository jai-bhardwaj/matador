import Foundation
import SwiftUI

@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Manifest: Decodable {
        let version: String
        let url: String
        let notes: String
        let date: String
    }

    var latest: Manifest?
    var available: Bool = false
    var error: String?

    func checkForUpdates() async {
        guard let url = URL(string: AppConstants.updateManifestURL) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            self.latest = manifest
            self.available = isNewer(manifest.version, than: AppConstants.version)
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func isNewer(_ a: String, than b: String) -> Bool {
        let aP = a.split(separator: ".").compactMap { Int($0) }
        let bP = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aP.count, bP.count) {
            let av = i < aP.count ? aP[i] : 0
            let bv = i < bP.count ? bP[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
