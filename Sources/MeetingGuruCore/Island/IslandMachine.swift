import Foundation

public enum IslandNotice: Equatable, Sendable {
    case noJoinLink(title: String)
    case openFailed(title: String)
    case replyFailed(title: String)

    public var message: String {
        switch self {
        case .noJoinLink: "No join link in this invite"
        case .openFailed: "Couldn’t open the join link"
        case .replyFailed: "Couldn’t send your reply"
        }
    }

    public var title: String {
        switch self {
        case .noJoinLink(let title), .openFailed(let title), .replyFailed(let title): title
        }
    }
}

/// What the island is doing. Only `peek`, `alert` and `invite` show the full meeting card.
public indirect enum IslandMode: Equatable, Sendable {
    case compact
    /// Opened by the user: hover (collapses on exit) or click (`pinned`, stays until dismissed).
    case peek(pinned: Bool)
    /// Raised by the scheduler; stays until the user acts or the meeting ends.
    case alert(fingerprint: String, autoJoined: Bool)
    /// A new invitation waiting for Accept / Maybe / Decline; stays until answered or put off.
    case invite(id: String)
    /// Short confirmation after a join, then back to compact.
    case joining(title: String, platform: String?)
    /// Short confirmation after answering an invite, then back to compact.
    case replied(title: String, response: InviteResponse)
    /// Short problem report, then back to `resume`.
    case notice(IslandNotice, resume: IslandMode)

    public var isExpanded: Bool {
        switch self {
        case .peek, .alert, .invite: true
        default: false
        }
    }

    public var isTransient: Bool {
        switch self {
        case .joining, .replied, .notice: true
        default: false
        }
    }

    public var transientDuration: TimeInterval? {
        switch self {
        case .joining, .replied: 1.8
        case .notice: 3.2
        default: nil
        }
    }
}

public enum IslandEvent: Equatable, Sendable {
    case hoverEntered
    case hoverExited
    case clicked
    case clickedOutside
    case escapePressed
    case alertRaised(fingerprint: String)
    case alertCleared
    case autoJoined(fingerprint: String)
    case joined(title: String, platform: String?)
    case joinFailed(IslandNotice)
    case acknowledged
    case transientElapsed
    case openRequested
    /// A new invitation arrived; only interrupts an idle island.
    case inviteRaised(id: String)
    /// The user picked an invitation from the menu.
    case inviteOpened(id: String)
    case inviteReplied(title: String, response: InviteResponse)
    case replyFailed(IslandNotice)
    /// The invitation was answered elsewhere or disappeared from the calendar.
    case inviteCleared
}

public enum IslandMachine {
    public static func reduce(_ mode: IslandMode, _ event: IslandEvent) -> IslandMode {
        switch (mode, event) {
        case (_, .alertRaised(let fingerprint)):
            if case .alert(let current, let autoJoined) = mode, current == fingerprint {
                return .alert(fingerprint: current, autoJoined: autoJoined)
            }
            return .alert(fingerprint: fingerprint, autoJoined: false)

        case (.compact, .hoverEntered): return .peek(pinned: false)
        case (.compact, .clicked), (.compact, .openRequested): return .peek(pinned: true)
        case (.compact, .joined(let title, let platform)): return .joining(title: title, platform: platform)
        case (.compact, .joinFailed(let notice)): return .notice(notice, resume: .compact)

        case (.peek(false), .hoverExited): return .compact
        case (.peek(false), .clicked), (.peek(false), .openRequested): return .peek(pinned: true)
        case (.peek(true), .clicked): return .compact
        case (.peek, .clickedOutside), (.peek, .escapePressed), (.peek, .acknowledged): return .compact
        case (.peek, .joined(let title, let platform)): return .joining(title: title, platform: platform)
        case (.peek, .joinFailed(let notice)): return .notice(notice, resume: mode)

        case (.alert(let fingerprint, _), .autoJoined(let joined)) where fingerprint == joined:
            return .alert(fingerprint: fingerprint, autoJoined: true)
        case (.alert, .alertCleared), (.alert, .acknowledged): return .compact
        case (.alert, .joined(let title, let platform)): return .joining(title: title, platform: platform)
        case (.alert, .joinFailed(let notice)): return .notice(notice, resume: mode)

        case (.compact, .inviteRaised(let id)): return .invite(id: id)
        case (.alert, .inviteOpened), (.notice(_, .alert), .inviteOpened): return mode
        case (_, .inviteOpened(let id)): return .invite(id: id)
        case (.invite, .acknowledged), (.invite, .inviteCleared): return .compact
        case (.invite, .inviteReplied(let title, let response)): return .replied(title: title, response: response)
        case (.invite, .replyFailed(let notice)): return .notice(notice, resume: mode)
        case (.notice(let notice, .invite), .inviteCleared): return .notice(notice, resume: .compact)

        case (.joining, .transientElapsed), (.replied, .transientElapsed): return .compact
        case (.notice(_, let resume), .transientElapsed): return resume
        case (.notice(let notice, .alert), .alertCleared): return .notice(notice, resume: .compact)

        default: return mode
        }
    }
}

/// How close the next meeting is. The collapsed island is only the mascot; urgency
/// tints it and makes the island glow: blue inside 15 minutes, orange inside 5, red inside 1.
public enum Urgency: Int, Comparable, Sendable {
    case none, upcoming, soon, now, paused

    public static let thresholds: [(Urgency, TimeInterval)] = [(.now, 60), (.soon, 300), (.upcoming, 900)]

    public static func make(schedule: MeetingSchedule, dndActive: Bool) -> Urgency {
        if dndActive { return .paused }
        guard let nearest = schedule.nearest else { return .none }
        let seconds = nearest.timeToStart(at: schedule.now)
        return thresholds.first { seconds <= $0.1 }?.0 ?? .none
    }

    public var glows: Bool { self == .upcoming || self == .soon || self == .now }

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
}
