import Foundation
import Testing

@testable import MeetingGuruCore

enum InviteFixture {
    static let resource = URL(string: "https://dav.example.com/calendars/me/work/inv.ics")!

    static func calendar(
        partstat: String? = "NEEDS-ACTION", organizer: String = "mailto:dana@example.com", start: String = "20260926T100000Z",
        extra: String = "", attendeeExtra: String = ""
    ) -> String {
        let param = partstat.map { ";PARTSTAT=\($0)" } ?? ""
        return """
            BEGIN:VCALENDAR\r
            VERSION:2.0\r
            BEGIN:VEVENT\r
            UID:inv-1\r
            SEQUENCE:2\r
            SUMMARY:Roadmap review\r
            DTSTART:\(start)\r
            DTEND:20260926T110000Z\r
            ORGANIZER;CN=Dana Smith:\(organizer)\r
            ATTENDEE;CN="Me: myself";ROLE=REQ-PARTICIPANT\(param);RSVP=TRUE\(attendeeExtra):mailto:me@example.com\r
            ATTENDEE;PARTSTAT=ACCEPTED:mailto:dana@example.com\r
            \(extra)BEGIN:VALARM\r
            ACTION:EMAIL\r
            ATTENDEE:mailto:me@example.com\r
            END:VALARM\r
            END:VEVENT\r
            END:VCALENDAR\r

            """
    }
}

@Suite struct InviteDetectorTests {
    let detector = InviteDetector(addresses: ["mailto:Me@Example.com"])
    let until = referenceNow.addingTimeInterval(CalDAVClient.inviteLookAhead)

    func detect(_ data: String) -> MeetingInvite? {
        detector.invite(resource: InviteFixture.resource, etag: "\"7\"", calendarData: data, now: referenceNow, until: until)
    }

    @Test func needsActionIsAnInvite() throws {
        let invite = try #require(detect(InviteFixture.calendar()))
        #expect(invite.meeting.title == "Roadmap review")
        #expect(invite.meeting.start == utc("2026-09-26T10:00:00Z"))
        #expect(invite.organizerName == "Dana Smith")
        #expect(invite.from == "Dana Smith")
        #expect(invite.etag == "\"7\"")
        #expect(!invite.isRecurring)
        #expect(invite.id == "inv-1||2|20260926T100000Z")
    }

    @Test func missingPartstatDefaultsToNeedsAction() {
        #expect(detect(InviteFixture.calendar(partstat: nil)) != nil)
    }

    @Test func answeredEventsAreNotInvites() {
        for answer in ["ACCEPTED", "DECLINED", "TENTATIVE"] {
            #expect(detect(InviteFixture.calendar(partstat: answer)) == nil)
        }
    }

    @Test func ownMeetingsCancelledAndPastOnesAreSkipped() {
        #expect(detect(InviteFixture.calendar(organizer: "mailto:me@example.com")) == nil)
        #expect(detect(InviteFixture.calendar(extra: "STATUS:CANCELLED\r\n")) == nil)
        #expect(
            detect(InviteFixture.calendar(start: "20260901T100000Z").replacingOccurrences(of: "20260926T110000Z", with: "20260901T110000Z")) == nil)
    }

    @Test func alarmAttendeesDoNotCount() {
        let data = InviteFixture.calendar(partstat: "ACCEPTED")
        #expect(data.contains("ACTION:EMAIL"))
        #expect(detect(data) == nil)
    }

    @Test func recurringInviteShowsTheNextOccurrence() throws {
        let data = InviteFixture.calendar(start: "20260901T100000Z", extra: "RRULE:FREQ=WEEKLY\r\n")
            .replacingOccurrences(of: "20260926T110000Z", with: "20260901T110000Z")
        let invite = try #require(detect(data))
        #expect(invite.isRecurring)
        #expect(invite.meeting.start == utc("2026-09-29T10:00:00Z"))
    }

    @Test func rescheduleChangesTheIdentity() throws {
        let first = try #require(detect(InviteFixture.calendar()))
        let moved = try #require(detect(InviteFixture.calendar(start: "20260926T093000Z")))
        #expect(first.id != moved.id)
    }

    @Test func noAddressesMeansNoInvites() {
        let blind = InviteDetector(addresses: [""])
        #expect(
            blind.invite(resource: InviteFixture.resource, etag: nil, calendarData: InviteFixture.calendar(), now: referenceNow, until: until) == nil)
    }
}

@Suite struct InviteAnswerTests {
    @Test func setsPartstatOnOwnAttendeeOnly() throws {
        let answered = try #require(ICalendar.answering(.accepted, as: ["me@example.com"], in: InviteFixture.calendar()))
        let lines = ICalendar.unfold(answered)
        let own = lines.filter { $0.hasPrefix("ATTENDEE") && $0.hasSuffix("mailto:me@example.com") }
        #expect(own.count == 2)
        #expect(own[0] == #"ATTENDEE;CN="Me: myself";ROLE=REQ-PARTICIPANT;RSVP=TRUE;PARTSTAT=ACCEPTED:mailto:me@example.com"#)
        #expect(own[1] == "ATTENDEE:mailto:me@example.com", "the VALARM recipient is left alone")
        #expect(lines.contains("ATTENDEE;PARTSTAT=ACCEPTED:mailto:dana@example.com"))
        #expect(lines.contains("SEQUENCE:2"))
        #expect(answered.hasSuffix("END:VCALENDAR\r\n"))
    }

    @Test func addsPartstatWhenMissing() throws {
        let answered = try #require(ICalendar.answering(.declined, as: ["me@example.com"], in: InviteFixture.calendar(partstat: nil)))
        #expect(ICalendar.unfold(answered).contains { $0.hasSuffix(";RSVP=TRUE;PARTSTAT=DECLINED:mailto:me@example.com") })
    }

    @Test func answersEveryEventInASeries() throws {
        let override = """
            BEGIN:VEVENT\r
            UID:inv-1\r
            RECURRENCE-ID:20261003T100000Z\r
            DTSTART:20261003T120000Z\r
            ORGANIZER:mailto:dana@example.com\r
            ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com\r
            END:VEVENT\r

            """
        let data = InviteFixture.calendar().replacingOccurrences(of: "END:VCALENDAR", with: override + "END:VCALENDAR")
        let answered = try #require(ICalendar.answering(.tentative, as: ["me@example.com"], in: data))
        #expect(answered.components(separatedBy: "PARTSTAT=TENTATIVE").count == 3)
        #expect(!answered.contains("NEEDS-ACTION"))
    }

    @Test func notAnAttendeeReturnsNil() {
        #expect(ICalendar.answering(.accepted, as: ["other@example.com"], in: InviteFixture.calendar()) == nil)
    }

    @Test func longLinesAreFoldedWithoutSplittingCharacters() {
        let line = "SUMMARY:" + String(repeating: "ü", count: 60)
        let folded = ICalendar.fold(line)
        let parts = folded.components(separatedBy: "\r\n")
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.utf8.count <= 75 })
        #expect(ICalendar.unfold(folded) == [line])
    }
}

@Suite struct InviteLedgerTests {
    @Test func remembersSeenInvitesAcrossLaunches() {
        let file = temporaryDirectory().appendingPathComponent("invites.json")
        let ledger = InviteLedger(fileURL: file)
        ledger.markSeen("a")
        ledger.markSeen("b")
        #expect(InviteLedger(fileURL: file).seen == ["a", "b"])

        ledger.retain(only: ["b", "c"])
        #expect(InviteLedger(fileURL: file).seen == ["b"])
    }

    @Test func memoryOnlyLedgerWritesNothing() {
        let ledger = InviteLedger(fileURL: nil)
        ledger.markSeen("a")
        #expect(ledger.contains("a"))
    }
}

@Suite struct CalDAVInviteTests {
    let range = CalDAVClient.inviteRange(now: referenceNow)

    func config() -> CalDAVConfig {
        CalDAVConfig(url: "https://dav.example.com/", username: "login", password: "pw")
    }

    /// The standard layout, with the principal advertising the user's address.
    func server(etag: String = "\"7\"", put: @escaping (URLRequest) -> (Int, String) = { _ in (204, "") }) -> FakeTransport {
        FakeTransport { request in
            let path = request.url!.path
            switch (request.httpMethod!, path) {
            case ("PROPFIND", "/principals/me"), ("PROPFIND", "/principals/me/"):
                return (
                    207,
                    Server.multistatus(
                        Server.response(
                            "/principals/me/",
                            "<cal:calendar-home-set><d:href>/calendars/me/</d:href></cal:calendar-home-set><cal:calendar-user-address-set><d:href>mailto:me@example.com</d:href><d:href>/principals/me@example.com/</d:href></cal:calendar-user-address-set>"
                        ))
                )
            case ("REPORT", _):
                let data = InviteFixture.calendar().replacingOccurrences(of: "&", with: "&amp;")
                return (
                    207,
                    Server.multistatus(
                        Server.response("/calendars/me/work/inv.ics", "<d:getetag>\(etag)</d:getetag><cal:calendar-data>\(data)</cal:calendar-data>")
                            + Server.response("/calendars/me/work/mine.ics", "<cal:calendar-data>\(Server.event)</cal:calendar-data>"))
                )
            case ("PUT", _):
                return put(request)
            case ("GET", _):
                return (200, InviteFixture.calendar(extra: "DESCRIPTION:updated\r\n"))
            default:
                return try Server.standard()(request)
            }
        }
    }

    @Test func learnsAddressesAndFindsInvites() async throws {
        let transport = server()
        let client = CalDAVClient(config: config(), transport: transport)
        let invites = try await client.invites(in: range)
        #expect(await client.addresses == ["login", "me@example.com"])
        #expect(invites.count == 1)
        #expect(invites.first?.resource.absoluteString == "https://dav.example.com/calendars/me/work/inv.ics")
        #expect(invites.first?.etag == "\"7\"")
        let report = try #require(transport.requests.last)
        let body = String(decoding: report.httpBody ?? Data(), as: UTF8.self)
        #expect(!body.contains("expand"), "invites need the stored resource, not an expansion")
    }

    @Test func replyIsAConditionalPut() async throws {
        let transport = server()
        let client = CalDAVClient(config: config(), transport: transport)
        let invite = try #require(try await client.invites(in: range).first)
        try await client.respond(to: invite, with: .accepted)

        let put = try #require(transport.requests.last)
        #expect(put.httpMethod == "PUT")
        #expect(put.url == InviteFixture.resource)
        #expect(put.value(forHTTPHeaderField: "If-Match") == "\"7\"")
        #expect(put.value(forHTTPHeaderField: "Content-Type") == "text/calendar; charset=utf-8")
        #expect(put.value(forHTTPHeaderField: "Depth") == nil)
        let body = ICalendar.unfold(String(decoding: put.httpBody ?? Data(), as: UTF8.self))
        #expect(body.contains { $0.hasSuffix(";PARTSTAT=ACCEPTED:mailto:me@example.com") })
    }

    @Test func changedResourceIsReReadOnce() async throws {
        var puts = 0
        let transport = server { _ in
            puts += 1
            return puts == 1 ? (412, "") : (204, "")
        }
        let client = CalDAVClient(config: config(), transport: transport)
        let invite = try #require(try await client.invites(in: range).first)
        try await client.respond(to: invite, with: .declined)

        let methods = transport.requests.suffix(3).map(\.httpMethod)
        #expect(methods == ["PUT", "GET", "PUT"])
        let body = ICalendar.unfold(String(decoding: transport.requests.last?.httpBody ?? Data(), as: UTF8.self))
        #expect(body.contains("DESCRIPTION:updated"))
        #expect(body.contains { $0.hasSuffix("PARTSTAT=DECLINED:mailto:me@example.com") })
    }

    @Test func rejectedReplyThrows() async throws {
        let client = CalDAVClient(config: config(), transport: server { _ in (403, "") })
        let invite = try #require(try await client.invites(in: range).first)
        await #expect(throws: CalDAVError.authentication("server answered 403")) {
            try await client.respond(to: invite, with: .accepted)
        }
    }
}

@Suite struct InviteIslandTests {
    typealias M = IslandMachine
    let failed = IslandNotice.replyFailed(title: "Roadmap")

    @Test func invitesOnlyInterruptAnIdleIsland() {
        #expect(M.reduce(.compact, .inviteRaised(id: "i")) == .invite(id: "i"))
        for mode: IslandMode in [.peek(pinned: false), .peek(pinned: true), .alert(fingerprint: "a", autoJoined: false)] {
            #expect(M.reduce(mode, .inviteRaised(id: "i")) == mode)
        }
    }

    @Test func menuOpensAnInviteButNeverOverAnAlert() {
        #expect(M.reduce(.peek(pinned: true), .inviteOpened(id: "i")) == .invite(id: "i"))
        #expect(M.reduce(.invite(id: "a"), .inviteOpened(id: "b")) == .invite(id: "b"))
        let alert = IslandMode.alert(fingerprint: "a", autoJoined: false)
        #expect(M.reduce(alert, .inviteOpened(id: "i")) == alert)
    }

    @Test func meetingAlertsWinOverInvites() {
        #expect(M.reduce(.invite(id: "i"), .alertRaised(fingerprint: "a")) == .alert(fingerprint: "a", autoJoined: false))
    }

    @Test func invitesStayUntilAnswered() {
        for event: IslandEvent in [.hoverExited, .clicked, .clickedOutside, .escapePressed] {
            #expect(M.reduce(.invite(id: "i"), event) == .invite(id: "i"))
        }
        #expect(M.reduce(.invite(id: "i"), .acknowledged) == .compact)
        #expect(M.reduce(.invite(id: "i"), .inviteCleared) == .compact)
    }

    @Test func answeringConfirmsThenCollapses() {
        let replied = M.reduce(.invite(id: "i"), .inviteReplied(title: "Roadmap", response: .accepted))
        #expect(replied == .replied(title: "Roadmap", response: .accepted))
        #expect(replied.transientDuration != nil)
        #expect(M.reduce(replied, .transientElapsed) == .compact)
    }

    @Test func failedReplyReturnsToTheInvite() {
        let shown = M.reduce(.invite(id: "i"), .replyFailed(failed))
        #expect(shown == .notice(failed, resume: .invite(id: "i")))
        #expect(M.reduce(shown, .transientElapsed) == .invite(id: "i"))
        #expect(M.reduce(shown, .inviteCleared) == .notice(failed, resume: .compact))
    }

    func invite(_ id: String, startIn hours: Double) -> MeetingInvite {
        MeetingInvite(
            id: id, meeting: meeting(id, startIn: hours * 60, location: "Room 2"), organizerName: "Dana", isRecurring: id == "weekly",
            resource: InviteFixture.resource)
    }

    func snapshot(_ mode: IslandMode, invites: [MeetingInvite], replying: InviteResponse? = nil) -> IslandSnapshot {
        IslandPresenter.snapshot(
            IslandInputs(
                mode: mode, events: [], now: referenceNow, timeZone: TimeZone(identifier: "UTC")!, invites: invites, replying: replying))
    }

    @Test func inviteCardOffersTheThreeAnswers() throws {
        let roadmap = invite("roadmap", startIn: 26)
        let card = try #require(snapshot(.invite(id: "roadmap"), invites: [roadmap]).card)
        #expect(card.headline == "roadmap")
        #expect(card.status == "New invite")
        #expect(card.statusTone == .azure)
        #expect(card.timeRange?.hasPrefix("Tomorrow · ") == true)
        #expect(card.place == "Room 2")
        #expect(card.invite == InviteCard(inviteID: "roadmap", from: "Dana", repeats: false, sending: nil))
        #expect(card.primary == nil)
        #expect(card.primaryEnabled)
        #expect(card.secondary == .later)
    }

    @Test func queuedInvitesShowTheirPosition() throws {
        let invites = [invite("roadmap", startIn: 26), invite("weekly", startIn: 72)]
        let card = try #require(snapshot(.invite(id: "weekly"), invites: invites).card)
        #expect(card.status == "Invite 2 of 2")
        #expect(card.invite?.repeats == true)
        #expect(card.timeRange?.hasPrefix("Today") == false)
        #expect(snapshot(.compact, invites: invites).pendingInvites == 2)
    }

    @Test func sendingDisablesTheButtons() throws {
        let card = try #require(snapshot(.invite(id: "roadmap"), invites: [invite("roadmap", startIn: 26)], replying: .declined).card)
        #expect(card.status == "Sending reply…")
        #expect(!card.primaryEnabled)
        #expect(card.invite?.sending == .declined)
    }

    @Test func vanishedInviteHasNoCard() {
        #expect(snapshot(.invite(id: "gone"), invites: []).card == nil)
    }
}

actor InvitingProvider: CalendarProvider {
    let failInvites: Bool
    init(failInvites: Bool) { self.failInvites = failInvites }

    func events(in range: DateInterval) async throws -> [MeetingEvent] { [meeting("m", startIn: 5)] }

    func invites(in range: DateInterval) async throws -> [MeetingInvite] {
        if failInvites { throw CalDAVError.connection("invites down") }
        return [MeetingInvite(id: "i", meeting: meeting("i", startIn: 600), resource: InviteFixture.resource)]
    }

    func reset() {}
}

@MainActor
@Suite struct SyncInviteTests {
    func sync(_ provider: InvitingProvider) async -> SyncResult? {
        let manager = SyncManager(provider: provider)
        var received: SyncResult?
        manager.onCompleted = { received = $0 }
        manager.startSync()
        for _ in 0..<200 where received == nil { try? await Task.sleep(for: .milliseconds(10)) }
        return received
    }

    @Test func syncCarriesInvites() async {
        let result = await sync(InvitingProvider(failInvites: false))
        #expect(result?.events.count == 1)
        #expect(result?.invites?.map(\.id) == ["i"])
    }

    @Test func failedInviteCheckKeepsTheSync() async {
        let result = await sync(InvitingProvider(failInvites: true))
        #expect(result?.events.count == 1)
        #expect(result?.invites == nil)
    }

    @Test func providersWithoutInvitesReportNone() async throws {
        let provider = ScriptedProvider([])
        #expect(try await provider.invites(in: CalDAVClient.inviteRange(now: referenceNow)).isEmpty)
        await #expect(throws: CalDAVError.self) {
            try await provider.respond(
                to: MeetingInvite(id: "i", meeting: meeting("i", startIn: 5), resource: InviteFixture.resource), with: .accepted)
        }
    }
}
