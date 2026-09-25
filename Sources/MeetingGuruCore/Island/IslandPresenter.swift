import Foundation

public enum Tone: Equatable, Sendable {
    case neutral, brass, coral, azure
}

public enum PrimaryAction: Equatable, Sendable {
    case join, rejoin, syncNow
}

public enum SecondaryAction: Equatable, Sendable {
    case dismiss, skipAlert, done, resumeAlerts, later
}

public struct CardContent: Equatable, Sendable {
    public var meeting: MeetingEvent?
    public var headline: String
    public var status: String
    public var statusTone: Tone
    public var isLive: Bool
    public var timeRange: String?
    public var place: String?
    public var progress: Double?
    /// Auto-join fuse: 0 when the alert appears, 1 when the meeting opens.
    public var fuse: Double?
    public var primary: PrimaryAction?
    public var primaryTitle: String
    public var primaryEnabled: Bool
    public var secondary: SecondaryAction?
    public var secondaryTitle: String?
    public var isAlert: Bool
    /// Set on an invitation card: it answers instead of joining.
    public var invite: InviteCard? = nil
}

public struct InviteCard: Equatable, Sendable {
    public var inviteID: String
    public var from: String?
    public var repeats: Bool
    /// The answer being sent; buttons stay disabled until the server confirms.
    public var sending: InviteResponse?
}

public struct FooterEntry: Equatable, Sendable {
    public var label: String
    public var time: String
    public var title: String
    public var relative: String?
}

public struct IslandSnapshot: Equatable, Sendable {
    public var mode: IslandMode
    public var urgency: Urgency
    public var syncError: String?
    public var card: CardContent?
    public var footer: [FooterEntry]
    public var footerNote: String?
    public var dndActive: Bool
    /// Invitations still waiting for an answer; the collapsed island shows a dot for them.
    public var pendingInvites: Int = 0

    public static let placeholder = IslandSnapshot(
        mode: .compact, urgency: .none, syncError: nil, card: nil, footer: [], footerNote: nil, dndActive: false)
}

/// Everything the presenter needs from the running app, captured at one instant.
public struct IslandInputs: Sendable {
    public var mode: IslandMode
    public var events: [MeetingEvent]
    public var alertMeeting: MeetingEvent?
    public var alertShownAt: Date?
    public var acknowledged: Set<String>
    public var autoJoinDelaySeconds: Int
    public var dnd: DNDState
    public var syncError: String?
    public var hasSynced: Bool
    public var now: Date
    public var timeZone: TimeZone
    public var invites: [MeetingInvite]
    public var replying: InviteResponse?

    public init(
        mode: IslandMode, events: [MeetingEvent], alertMeeting: MeetingEvent? = nil, alertShownAt: Date? = nil,
        acknowledged: Set<String> = [], autoJoinDelaySeconds: Int = 5, dnd: DNDState = DNDState(),
        syncError: String? = nil, hasSynced: Bool = true, now: Date, timeZone: TimeZone = .current,
        invites: [MeetingInvite] = [], replying: InviteResponse? = nil
    ) {
        self.mode = mode
        self.events = events
        self.alertMeeting = alertMeeting
        self.alertShownAt = alertShownAt
        self.acknowledged = acknowledged
        self.autoJoinDelaySeconds = autoJoinDelaySeconds
        self.dnd = dnd
        self.syncError = syncError
        self.hasSynced = hasSynced
        self.now = now
        self.timeZone = timeZone
        self.invites = invites
        self.replying = replying
    }
}

public enum IslandPresenter {
    public static func snapshot(_ input: IslandInputs) -> IslandSnapshot {
        let schedule = MeetingSchedule(events: input.events, now: input.now)
        let dndActive = input.dnd.isActive(at: input.now)
        var card: CardContent?
        switch input.mode {
        case .alert(let fingerprint, let autoJoined):
            let meeting =
                input.alertMeeting?.fingerprint == fingerprint
                ? input.alertMeeting : input.events.first { $0.fingerprint == fingerprint }
            card = meeting.map { alertCard($0, autoJoined: autoJoined, input: input) }
        case .peek, .notice(_, .peek):
            card = peekCard(schedule.featured, input: input, dndActive: dndActive)
        case .invite(let id), .notice(_, .invite(let id)):
            card = input.invites.firstIndex { $0.id == id }.map { inviteCard(at: $0, input: input) }
        default:
            break
        }
        return IslandSnapshot(
            mode: input.mode,
            urgency: Urgency.make(schedule: schedule, dndActive: dndActive),
            syncError: input.syncError,
            card: card,
            footer: footer(schedule, input: input),
            footerNote: footerNote(schedule, input: input),
            dndActive: dndActive,
            pendingInvites: input.invites.count)
    }

    static func inviteCard(at index: Int, input: IslandInputs) -> CardContent {
        let invite = input.invites[index]
        let meeting = invite.meeting
        let status: String
        if input.replying != nil {
            status = "Sending reply…"
        } else if input.invites.count > 1 {
            status = "Invite \(index + 1) of \(input.invites.count)"
        } else {
            status = "New invite"
        }
        return CardContent(
            meeting: meeting,
            headline: meeting.title,
            status: status,
            statusTone: .azure,
            isLive: false,
            timeRange: Formatting.dayAndTime(meeting, now: input.now, timeZone: input.timeZone),
            place: place(for: meeting),
            progress: nil,
            fuse: nil,
            primary: nil,
            primaryTitle: InviteResponse.accepted.label,
            primaryEnabled: input.replying == nil,
            secondary: .later,
            secondaryTitle: "Later",
            isAlert: false,
            invite: InviteCard(inviteID: invite.id, from: invite.from, repeats: invite.isRecurring, sending: input.replying))
    }

    static func alertCard(_ meeting: MeetingEvent, autoJoined: Bool, input: IslandInputs) -> CardContent {
        let now = input.now
        let live = meeting.status(at: now) != .upcoming
        let hasLink = meeting.meetingURL != nil
        var status: String
        var tone: Tone
        if live {
            let late = Formatting.minutes(meeting.timeSinceStart(at: now))
            status = late < 1 ? "Starting now" : "\(late) min late"
            tone = .coral
        } else {
            status = "Starts in \(Formatting.countdown(meeting.timeToStart(at: now)))"
            tone = .brass
        }

        var fuse: Double?
        var primaryTitle = hasLink ? "Join" : "No link"
        if autoJoined {
            status = "Opened automatically"
            tone = .neutral
            primaryTitle = "Rejoin"
        } else if hasLink, input.autoJoinDelaySeconds > 0, let shownAt = input.alertShownAt {
            let elapsed = now.timeIntervalSince(shownAt)
            let delay = Double(input.autoJoinDelaySeconds)
            fuse = min(1, max(0, elapsed / delay))
            let left = Int((delay - elapsed).rounded(.up))
            if left > 0 { primaryTitle = "Join · \(left)" }
        }

        return CardContent(
            meeting: meeting,
            headline: meeting.title,
            status: status,
            statusTone: tone,
            isLive: live,
            timeRange: Formatting.timeRange(meeting, timeZone: input.timeZone),
            place: place(for: meeting),
            progress: live ? meeting.progress(at: now) : nil,
            fuse: fuse,
            primary: hasLink ? (autoJoined ? .rejoin : .join) : nil,
            primaryTitle: primaryTitle,
            primaryEnabled: hasLink,
            secondary: autoJoined ? .done : .dismiss,
            secondaryTitle: autoJoined ? "Done" : "Dismiss",
            isAlert: true)
    }

    static func peekCard(_ featured: MeetingEvent?, input: IslandInputs, dndActive: Bool) -> CardContent {
        let now = input.now
        let pausedSecondary: (SecondaryAction?, String?) = dndActive ? (.resumeAlerts, "Resume alerts") : (nil, nil)
        guard let meeting = featured else {
            return CardContent(
                meeting: nil,
                headline: input.hasSynced ? "Nothing on your calendar" : "Waiting for your calendar",
                status: dndActive ? pausedStatus(input) : "Next 2 days",
                statusTone: dndActive ? .brass : .neutral,
                isLive: false, timeRange: nil,
                place: input.hasSynced ? "Your next two days are clear." : "Syncing with your CalDAV server…",
                progress: nil, fuse: nil,
                primary: .syncNow, primaryTitle: "Sync now", primaryEnabled: true,
                secondary: pausedSecondary.0, secondaryTitle: pausedSecondary.1, isAlert: false)
        }

        let live = meeting.status(at: now) == .current
        let hasLink = meeting.meetingURL != nil
        var status: String
        var tone: Tone = .neutral
        if dndActive {
            status = pausedStatus(input)
            tone = .brass
        } else if live {
            status = "\(Formatting.shortDuration(meeting.end.timeIntervalSince(now))) left"
        } else {
            let until = meeting.timeToStart(at: now)
            status = until < 3600 ? "Starts in \(Formatting.countdown(until))" : "In \(Formatting.shortDuration(until))"
            if meeting.isWithin(minutes: MeetingSchedule.warningMinutes, at: now) { tone = .brass }
        }

        var secondary = pausedSecondary
        if !dndActive, !input.acknowledged.contains(meeting.fingerprint) {
            secondary = (.skipAlert, "Skip alert")
        }

        return CardContent(
            meeting: meeting,
            headline: meeting.title,
            status: status,
            statusTone: tone,
            isLive: live,
            timeRange: Formatting.timeRange(meeting, timeZone: input.timeZone),
            place: place(for: meeting),
            progress: live ? meeting.progress(at: now) : nil,
            fuse: nil,
            primary: hasLink ? .join : nil,
            primaryTitle: hasLink ? "Join" : "No link",
            primaryEnabled: hasLink,
            secondary: secondary.0,
            secondaryTitle: secondary.1,
            isAlert: false)
    }

    static func footer(_ schedule: MeetingSchedule, input: IslandInputs) -> [FooterEntry] {
        var entries: [FooterEntry] = []
        if let nearest = schedule.nearest {
            entries.append(
                FooterEntry(
                    label: "Nearest",
                    time: Formatting.clock(nearest.start, timeZone: input.timeZone),
                    title: nearest.title,
                    relative: "in \(Formatting.shortDuration(max(60, nearest.timeToStart(at: input.now))))"))
        }
        if let next = schedule.next {
            entries.append(
                FooterEntry(
                    label: "Next",
                    time: Formatting.clock(next.start, timeZone: input.timeZone),
                    title: next.title,
                    relative: nil))
        }
        return entries
    }

    static func footerNote(_ schedule: MeetingSchedule, input: IslandInputs) -> String? {
        if input.syncError != nil { return "Calendar sync failed — showing the last good copy" }
        if schedule.upcoming.isEmpty, input.hasSynced { return "No more meetings in the next 2 days" }
        return nil
    }

    static func pausedStatus(_ input: IslandInputs) -> String {
        "Alerts paused · \(input.dnd.summary(at: input.now) ?? "on")"
    }

    /// "Room 4 · Zoom", "Google Meet", or the plain location.
    public static func place(for meeting: MeetingEvent) -> String? {
        let platform = MeetingLinks.platformName(for: meeting.meetingURL)
        let location = meeting.location.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || !MeetingLinks.findURLs(in: trimmed).isEmpty && trimmed.hasPrefix("http") { return nil }
            return trimmed
        }
        switch (location, platform) {
        case let (location?, platform?): return "\(location) · \(platform)"
        case let (location?, nil): return location
        case let (nil, platform?): return platform
        default: return nil
        }
    }
}
