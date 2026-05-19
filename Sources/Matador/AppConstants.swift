import Foundation

enum AppConstants {
    static let version = "0.2.6"
    static let appName = "Matador"
    static let bundleID = "com.matador.app"

    /// Primary update source — always fresh, no CDN cache. Rate-limited to 60
    /// req/hr unauthenticated, which is plenty for an app that checks on
    /// launch + explicit "Check for Updates" clicks.
    static let updateReleasesAPI = "https://api.github.com/repos/jai-bhardwaj/matador/releases/latest"

    /// Fallback if the API is rate-limited or otherwise unreachable. Served
    /// via Fastly which can be minutes stale on regional edges — only used
    /// as a backup.
    static let updateManifestURL = "https://raw.githubusercontent.com/jai-bhardwaj/matador/main/release/latest.json"
}
