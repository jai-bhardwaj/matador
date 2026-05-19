import Foundation
import SwiftUI

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    var queuePollSeconds: Int {
        didSet { UserDefaults.standard.set(queuePollSeconds, forKey: "queuePollSeconds") }
    }
    var jobPollSeconds: Int {
        didSet { UserDefaults.standard.set(jobPollSeconds, forKey: "jobPollSeconds") }
    }
    var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    var pageSize: Int {
        didSet { UserDefaults.standard.set(pageSize, forKey: "pageSize") }
    }

    init() {
        let ud = UserDefaults.standard
        self.queuePollSeconds = max(1, min(60, ud.object(forKey: "queuePollSeconds") as? Int ?? 5))
        self.jobPollSeconds = max(1, min(60, ud.object(forKey: "jobPollSeconds") as? Int ?? 4))
        self.appearance = AppearanceMode(rawValue: ud.string(forKey: "appearance") ?? "") ?? .system
        self.pageSize = max(10, min(500, ud.object(forKey: "pageSize") as? Int ?? 50))
    }
}
