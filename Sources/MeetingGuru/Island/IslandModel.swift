import MeetingGuruCore
import Observation
import SwiftUI

@MainActor
@Observable
final class IslandModel {
    var snapshot = IslandSnapshot.placeholder
    var backgroundIndex = 0
    var islandSize = CGSize(width: 48, height: 30) {
        didSet { if islandSize != oldValue { onResize() } }
    }

    @ObservationIgnored var onResize: () -> Void = {}

    @ObservationIgnored var send: (IslandEvent) -> Void = { _ in }
    @ObservationIgnored var primary: (PrimaryAction, MeetingEvent?) -> Void = { _, _ in }
    @ObservationIgnored var secondary: (SecondaryAction, MeetingEvent?) -> Void = { _, _ in }
    @ObservationIgnored var respond: (String, InviteResponse) -> Void = { _, _ in }
}

enum Palette {
    static let ink = Color(white: 0.96)
    static let dim = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.40)
    static let hairline = Color.white.opacity(0.11)
    static let brass = Color(red: 0xD8 / 255, green: 0xB8 / 255, blue: 0x78 / 255)
    static let coral = Color(red: 0xFF / 255, green: 0x6F / 255, blue: 0x5B / 255)

    static let urgencyBlue = Color(red: 0x4D / 255, green: 0xA3 / 255, blue: 1)
    static let urgencyOrange = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
    static let urgencyRed = Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)

    static func urgency(_ urgency: Urgency) -> Color {
        switch urgency {
        case .upcoming: urgencyBlue
        case .soon: urgencyOrange
        case .now: urgencyRed
        case .none, .paused: .white
        }
    }

    static func tone(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: ink
        case .brass: brass
        case .coral: coral
        case .azure: urgencyBlue
        }
    }
}

enum Metrics {
    static let panelSize = CGSize(width: 440, height: 420)
    /// The open card's top sits this fraction of the screen height below the top edge.
    static let topFraction: CGFloat = 0.10
    /// Half an open card's typical height: the collapsed island sits this far below
    /// the card's top so the card grows out of, and folds back into, its centre.
    static let cardHalfHeight: CGFloat = 110
    static let cardWidth: CGFloat = 372
    static let rightInset: CGFloat = 0
}
