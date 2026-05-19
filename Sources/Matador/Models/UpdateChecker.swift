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

    /// Shape of the relevant slice of api.github.com/.../releases/latest.
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String       // "v0.2.3"
        let name: String?          // "Matador 0.2.3"
        let body: String?
        let published_at: String?
        let assets: [Asset]
    }

    var latest: Manifest?
    var available: Bool = false
    var error: String?

    func checkForUpdates() async {
        // Primary: GitHub Releases API. No CDN cache, always current.
        if let m = await fetchFromReleasesAPI() {
            apply(manifest: m, source: "api")
            return
        }
        // Fallback: raw manifest with cache-busting. Can lag by minutes on
        // regional Fastly edges, but better than nothing if the API rate-limits.
        if let m = await fetchFromRawManifest() {
            apply(manifest: m, source: "raw")
            return
        }
        // Both failed — leave error set from whichever attempt failed last.
    }

    private func apply(manifest: Manifest, source: String) {
        self.latest = manifest
        self.available = isNewer(manifest.version, than: AppConstants.version)
        self.error = nil
    }

    // MARK: API path

    private func fetchFromReleasesAPI() async -> Manifest? {
        guard let url = URL(string: AppConstants.updateReleasesAPI) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // The API serves a different payload depending on the Accept header,
        // but for our purposes the default JSON is fine.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Matador/\(AppConstants.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 403 {
                // Rate-limited — fall through to raw manifest
                self.error = "GitHub API rate-limited (HTTP 403) — falling back to manifest"
                return nil
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            // tag_name like "v0.2.3" — strip the leading "v"
            let version = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst())
                : release.tag_name
            // First .dmg asset is the install target
            guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                self.error = "Latest release has no .dmg asset"
                return nil
            }
            return Manifest(
                version: version,
                url: dmg.browser_download_url,
                notes: release.body ?? release.name ?? "Matador \(version)",
                date: String((release.published_at ?? "").prefix(10))
            )
        } catch {
            self.error = "GitHub API: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Raw manifest fallback

    private func fetchFromRawManifest() async -> Manifest? {
        guard var components = URLComponents(string: AppConstants.updateManifestURL) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970)))
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            // Don't clobber the API error if there is one.
            if self.error == nil {
                self.error = "Manifest fetch: \(error.localizedDescription)"
            }
            return nil
        }
    }

    // MARK: Version compare

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
