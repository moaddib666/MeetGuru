import AppKit
import MeetingGuruCore
import SwiftUI

/// Renders every island state offscreen — used for design review and as a smoke test of the views.
@MainActor
enum Gallery {
    static func states(now: Date) -> [(String, IslandSnapshot)] {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        let standup = MeetingEvent(
            uid: "standup", title: "Platform standup", start: at(0.7), end: at(30.7),
            location: "https://meet.google.com/abc-defg-hij")
        let review = MeetingEvent(
            uid: "review", title: "Design review: island interactions and alert timing", start: at(-12), end: at(33),
            location: "Room 4", details: "Join https://us02web.zoom.us/j/123456")
        let planning = MeetingEvent(uid: "planning", title: "Quarterly planning", start: at(95), end: at(155), location: "Kyiv office")
        let oneOnOne = MeetingEvent(
            uid: "1on1", title: "1:1 with Dana", start: at(210), end: at(240), url: "https://teams.microsoft.com/l/meetup-join/x")
        let noLink = MeetingEvent(uid: "nolink", title: "Coffee chat", start: at(8), end: at(38), location: "Kitchen")

        func meetingIn(_ minutes: Double) -> MeetingEvent {
            MeetingEvent(
                uid: "soon-\(minutes)", title: "Platform standup", start: at(minutes), end: at(minutes + 30),
                location: "https://meet.google.com/abc-defg-hij")
        }

        var paused = DNDState()
        paused.start(.oneHour, at: now.addingTimeInterval(-18 * 60))

        let roadmap = MeetingInvite(
            id: "roadmap",
            meeting: MeetingEvent(
                uid: "roadmap", title: "Roadmap review with product", start: at(26 * 60), end: at(27 * 60),
                location: "https://meet.google.com/xyz-abcd-efg", organizer: "dana@example.com"),
            organizerName: "Dana Smith", resource: URL(string: "https://dav.example.com/roadmap.ics")!)
        let weekly = MeetingInvite(
            id: "weekly",
            meeting: MeetingEvent(
                uid: "weekly", title: "Infra weekly sync", start: at(3 * 24 * 60), end: at(3 * 24 * 60 + 45),
                location: "Room 2", organizer: "ops@example.com"),
            isRecurring: true, resource: URL(string: "https://dav.example.com/weekly.ics")!)

        func snap(
            _ mode: IslandMode, _ events: [MeetingEvent], alert: MeetingEvent? = nil, shownAgo: Double? = nil,
            dnd: DNDState = DNDState(), error: String? = nil, synced: Bool = true,
            invites: [MeetingInvite] = [], replying: InviteResponse? = nil
        ) -> IslandSnapshot {
            IslandPresenter.snapshot(
                IslandInputs(
                    mode: mode, events: events, alertMeeting: alert,
                    alertShownAt: shownAgo.map { now.addingTimeInterval(-$0) },
                    autoJoinDelaySeconds: 5, dnd: dnd, syncError: error, hasSynced: synced, now: now,
                    invites: invites, replying: replying))
        }

        let day = [standup, planning, oneOnOne]
        return [
            ("01-compact", snap(.compact, [planning])),
            ("02-compact-15min-blue", snap(.compact, [meetingIn(12), planning])),
            ("02b-compact-5min-orange", snap(.compact, [meetingIn(4), planning])),
            ("02c-compact-1min-red", snap(.compact, [meetingIn(0.8), planning])),
            ("03-compact-live", snap(.compact, [review, planning])),
            ("04-compact-paused", snap(.compact, day, dnd: paused)),
            ("05-compact-sync-error", snap(.compact, [planning], error: "Connection failed: timed out")),
            ("06-peek-upcoming", snap(.peek(pinned: false), [planning, oneOnOne])),
            ("07-peek-live", snap(.peek(pinned: true), [review, planning, oneOnOne])),
            ("08-peek-empty", snap(.peek(pinned: true), [])),
            ("09-peek-paused", snap(.peek(pinned: true), day, dnd: paused)),
            ("10-peek-sync-error", snap(.peek(pinned: true), [planning, oneOnOne], error: "Connection failed: timed out")),
            ("11-alert-countdown", snap(.alert(fingerprint: standup.fingerprint, autoJoined: false), day, alert: standup, shownAgo: 2)),
            (
                "12-alert-late",
                snap(.alert(fingerprint: review.fingerprint, autoJoined: false), [review, planning, oneOnOne], alert: review, shownAgo: 4)
            ),
            ("13-alert-auto-joined", snap(.alert(fingerprint: standup.fingerprint, autoJoined: true), day, alert: standup, shownAgo: 9)),
            ("14-alert-no-link", snap(.alert(fingerprint: noLink.fingerprint, autoJoined: false), [noLink, planning], alert: noLink, shownAgo: 1)),
            ("15-joining", snap(.joining(title: standup.title, platform: "Google Meet"), day)),
            ("16-notice-no-link", snap(.notice(.noJoinLink(title: noLink.title), resume: .compact), [noLink])),
            ("17-compact-invites-waiting", snap(.compact, [planning], invites: [roadmap])),
            ("18-invite", snap(.invite(id: roadmap.id), day, invites: [roadmap])),
            ("19-invite-recurring-2-of-2", snap(.invite(id: weekly.id), day, invites: [roadmap, weekly])),
            ("20-invite-sending", snap(.invite(id: roadmap.id), day, invites: [roadmap], replying: .accepted)),
            ("21-replied-accepted", snap(.replied(title: roadmap.meeting.title, response: .accepted), day)),
            ("22-replied-declined", snap(.replied(title: weekly.meeting.title, response: .declined), day)),
            (
                "23-notice-reply-failed",
                snap(.notice(.replyFailed(title: roadmap.meeting.title), resume: .invite(id: roadmap.id)), day, invites: [roadmap])
            ),
        ]
    }

    static func menuHeaders(now: Date) -> [(String, MenuHeaderView)] {
        let soon = MeetingEvent(
            uid: "m", title: "Platform standup", start: now.addingTimeInterval(4 * 60), end: now.addingTimeInterval(34 * 60),
            location: "https://meet.google.com/abc-defg-hij")
        let later = MeetingEvent(uid: "l", title: "Quarterly planning", start: now.addingTimeInterval(95 * 60), end: now.addingTimeInterval(155 * 60))
        var paused = DNDState()
        paused.start(.oneHour, at: now.addingTimeInterval(-18 * 60))
        return [
            ("menu-1-soon", MenuHeaderView(meeting: soon, now: now, dnd: DNDState(), syncError: nil, urgency: .soon)),
            ("menu-2-later", MenuHeaderView(meeting: later, now: now, dnd: DNDState(), syncError: nil, urgency: .none)),
            ("menu-3-paused", MenuHeaderView(meeting: later, now: now, dnd: paused, syncError: nil, urgency: .paused)),
            ("menu-4-empty", MenuHeaderView(meeting: nil, now: now, dnd: DNDState(), syncError: nil, urgency: .none)),
            ("menu-5-sync-error", MenuHeaderView(meeting: later, now: now, dnd: DNDState(), syncError: "timed out", urgency: .none)),
        ]
    }

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, header) in menuHeaders(now: Date()) {
            let renderer = ImageRenderer(content: header.frame(width: 300).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
                print(directory.appendingPathComponent("\(name).png").path)
            }
        }
        for (index, (name, snapshot)) in states(now: Date()).enumerated() {
            let model = IslandModel()
            model.snapshot = snapshot
            model.backgroundIndex = index % Assets.backgroundCount
            let view = ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(red: 0x3B / 255, green: 0x46 / 255, blue: 0x60 / 255), Color(red: 0x14 / 255, green: 0x18 / 255, blue: 0x21 / 255),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                IslandRootView(model: model, animated: false)
            }
            .frame(width: Metrics.panelSize.width, height: Metrics.panelSize.height, alignment: .topTrailing)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
            print(directory.appendingPathComponent("\(name).png").path)
        }
    }
}
