import SwiftUI

/// Matador's visual language. Centralised so a re-theme is a one-file change.
enum Theme {
    // Brand
    static let brand = Color(red: 0.78, green: 0.15, blue: 0.20)        // crimson cape
    static let brandSoft = Color(red: 0.78, green: 0.15, blue: 0.20).opacity(0.14)

    // Semantic state colours — slightly desaturated vs system, easier on the eyes
    static let waiting     = Color(red: 0.40, green: 0.55, blue: 0.95)  // soft blue
    static let active      = Color(red: 0.35, green: 0.80, blue: 0.55)  // mint
    static let completed   = Color(red: 0.45, green: 0.45, blue: 0.55)  // muted
    static let failed      = Color(red: 0.92, green: 0.42, blue: 0.42)  // coral
    static let delayed     = Color(red: 0.95, green: 0.75, blue: 0.30)  // amber
    static let prioritized = Color(red: 0.75, green: 0.55, blue: 0.95)  // lilac
    static let paused      = Color(red: 0.70, green: 0.65, blue: 0.55)  // sand

    // Surfaces
    static let surfaceElevated = AnyShapeStyle(.regularMaterial)
    static let surfaceCard     = AnyShapeStyle(.thinMaterial)
    static let codeBg          = Color.secondary.opacity(0.08)

    // Type
    static let mono = Font.system(.callout, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    static let monoTiny = Font.system(.caption2, design: .monospaced)
    static let displayTitle = Font.system(.title2, design: .rounded).weight(.semibold)
    static let sectionLabel = Font.caption.smallCaps().weight(.medium)
}

extension JobState {
    var accent: Color {
        switch self {
        case .waiting: return Theme.waiting
        case .active: return Theme.active
        case .completed: return Theme.completed
        case .failed: return Theme.failed
        case .delayed: return Theme.delayed
        case .prioritized: return Theme.prioritized
        case .paused, .waitingChildren: return Theme.paused
        }
    }

    var systemIcon: String {
        switch self {
        case .waiting: return "tray"
        case .active: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .delayed: return "clock"
        case .prioritized: return "arrow.up.right.circle"
        case .paused: return "pause.circle"
        case .waitingChildren: return "person.2"
        }
    }
}

// MARK: - View modifiers

extension View {
    /// Inset card surface with subtle border + radius.
    func cardStyle() -> some View {
        self
            .padding(12)
            .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    /// Monospaced code block.
    func codeBlock() -> some View {
        self
            .font(Theme.monoSmall)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }
}
