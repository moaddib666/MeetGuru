import CryptoKit
import Foundation

public enum MeetingStatus: String, Sendable {
    case upcoming, current, missed, completed
}

public enum AlertStatus: String, Sendable {
    case pending, showing, dismissed
    case autoJoined = "auto_joined"
    case missed
}

public struct MeetingEvent: Sendable, Hashable, Identifiable {
    public var uid: String
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var details: String?
    public var url: String?
    public var organizer: String?
    public var attendees: [String]
    public var allDay: Bool
    public var conferenceURLs: [String]

    public init(
        uid: String,
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        details: String? = nil,
        url: String? = nil,
        organizer: String? = nil,
        attendees: [String] = [],
        allDay: Bool = false,
        conferenceURLs: [String] = []
    ) {
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.details = details
        self.url = url
        self.organizer = organizer
        self.attendees = attendees
        self.allDay = allDay
        self.conferenceURLs = conferenceURLs
    }

    public var id: String { fingerprint }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func status(at now: Date) -> MeetingStatus {
        if now < start { return .upcoming }
        if now <= end { return .current }
        return .completed
    }

    public func timeToStart(at now: Date) -> TimeInterval { start.timeIntervalSince(now) }

    public func timeSinceStart(at now: Date) -> TimeInterval { now.timeIntervalSince(start) }

    public func isWithin(minutes: Int, at now: Date) -> Bool {
        let seconds = timeToStart(at: now)
        return seconds >= 0 && seconds <= Double(minutes * 60)
    }

    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, timeSinceStart(at: now) / duration))
    }

    public var meetingURL: String? {
        MeetingLinks.bestJoinLink(from: conferenceURLs + [url, location, details])
    }

    /// Mirrors the Python fingerprint: sha256("uid|title|isoStart|location")[:16].
    public var fingerprint: String {
        let parts = [uid, title, Self.isoFormatter.string(from: start), location ?? ""]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}

public struct SyncResult: Sendable {
    public var events: [MeetingEvent]
    public var syncTime: Date
    /// Nil when the invitation check failed, so the last known list is kept.
    public var invites: [MeetingInvite]?

    public init(events: [MeetingEvent], syncTime: Date, invites: [MeetingInvite]? = nil) {
        self.events = events
        self.syncTime = syncTime
        self.invites = invites
    }
}
