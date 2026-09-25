import Foundation
import Testing

@testable import MeetingGuruCore

@Suite struct MeetingLinkTests {
    @Test(
        arguments: [
            (
                ["https://calendar.example.com/event/1", "Room 4", "Join https://us02web.zoom.us/j/1?pwd=x&amp;y=2."],
                "https://us02web.zoom.us/j/1?pwd=x&y=2"
            ),
            ([nil, nil, "<a href=\"https://meet.google.com/abc-defg-hij\">Join</a>"], "https://meet.google.com/abc-defg-hij"),
            (
                [
                    nil,
                    "https://nam.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting%2540thread.v2%2F0&data=1",
                    nil,
                ],
                "https://teams.microsoft.com/l/meetup-join/19%3ameeting%40thread.v2/0"
            ),
            ([nil, "see https://example.com/room)", nil], "https://example.com/room"),
            ([nil, "Office", nil], nil),
            ([nil, "Jira https://track.example.net/browse/X-1", "Join https://meet.example.net/room-42"], "https://meet.example.net/room-42"),
        ] as [([String?], String?)])
    func findsTheBestJoinLink(sources: [String?], expected: String?) {
        #expect(MeetingLinks.bestJoinLink(from: sources) == expected)
    }

    @Test func descriptionLinkUsedWhenLocationHasNone() {
        let m = meeting("m", startIn: 1, location: "Kyiv office", details: "Teams: https://teams.microsoft.com/l/meetup-join/abc")
        #expect(m.meetingURL == "https://teams.microsoft.com/l/meetup-join/abc")
    }

    @Test func conferencePropertyPreferred() {
        let m = meeting("m", startIn: 1, url: "https://calendar.google.com/x", conferenceURLs: ["https://meet.google.com/aaa-bbbb-ccc"])
        #expect(m.meetingURL == "https://meet.google.com/aaa-bbbb-ccc")
    }

    @Test func platformNames() {
        #expect(MeetingLinks.platformName(for: "https://us02web.zoom.us/j/1") == "Zoom")
        #expect(MeetingLinks.platformName(for: "https://meet.google.com/x") == "Google Meet")
        #expect(MeetingLinks.platformName(for: "https://teams.microsoft.com/l/x") == "Microsoft Teams")
        #expect(MeetingLinks.platformName(for: "https://www.example.org/room") == "example.org")
        #expect(MeetingLinks.platformName(for: nil) == nil)
    }

    @Test func onlyHttpLinksAreOpened() {
        #expect(MeetingLinks.isOpenable("https://zoom.us/j/1"))
        #expect(!MeetingLinks.isOpenable("javascript:alert(1)"))
        #expect(!MeetingLinks.isOpenable("file:///etc/passwd"))
    }
}

@Suite struct EventParsingTests {
    let parser = EventParser(ownAddress: "me@example.com")
    let range = DateInterval(start: utc("2026-09-20T00:00:00Z"), end: utc("2026-09-27T00:00:00Z"))

    func one(_ body: String) -> MeetingEvent? {
        parser.meetings(from: ical(body), range: range).first
    }

    @Test func mixedTimezoneFloatingAndAllDayTimesAreComparable() throws {
        let utcEvent = try #require(one("DTSTART:20260923T100000Z\r\nDTEND:20260923T103000Z\r\n"))
        let floating = try #require(one("DTSTART:20260923T110000\r\nDTEND:20260923T113000\r\n"))
        let allDay = try #require(one("DTSTART;VALUE=DATE:20260923\r\nDTEND;VALUE=DATE:20260924\r\n"))

        #expect(utcEvent.start == utc("2026-09-23T10:00:00Z"))
        #expect(!utcEvent.allDay)
        #expect(allDay.allDay)
        #expect(allDay.duration == 86_400)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        #expect(local.component(.hour, from: floating.start) == 11)
    }

    @Test func cancelledEventSkipped() {
        #expect(one("DTSTART:20260923T100000Z\r\nSTATUS:CANCELLED\r\n") == nil)
    }

    @Test func declinedEventSkipped() {
        #expect(one("DTSTART:20260923T100000Z\r\nATTENDEE;PARTSTAT=DECLINED:mailto:me@example.com\r\n") == nil)
    }

    @Test func someoneElseDecliningKeepsTheEvent() {
        #expect(one("DTSTART:20260923T100000Z\r\nATTENDEE;PARTSTAT=DECLINED:mailto:other@example.com\r\n") != nil)
    }

    @Test func acceptedEventKeptWithConferenceLink() throws {
        let event = try #require(
            one(
                "DTSTART:20260923T100000Z\r\nDURATION:PT45M\r\n"
                    + "ATTENDEE;PARTSTAT=ACCEPTED:mailto:me@example.com\r\n"
                    + "X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij\r\n"))
        #expect(event.duration == 45 * 60)
        #expect(event.meetingURL == "https://meet.google.com/abc-defg-hij")
        #expect(event.attendees == ["me@example.com"])
    }

    @Test func missingEndDefaultsToAnHour() throws {
        #expect(try #require(one("DTSTART:20260923T100000Z\r\n")).duration == 3600)
    }

    @Test func foldedAndEscapedTextIsUnfolded() throws {
        let event = try #require(
            parser.meetings(
                from: """
                    BEGIN:VCALENDAR\r
                    BEGIN:VEVENT\r
                    UID:x\r
                    SUMMARY:Plan\\, review\\; ship\r
                    DESCRIPTION:Line one\\nJoin https://zoom.us/j/12\r
                     345\r
                    LOCATION;LANGUAGE=en:Room 4\r
                    ORGANIZER;CN="Boss, The":mailto:boss@example.com\r
                    DTSTART:20260923T100000Z\r
                    END:VEVENT\r
                    END:VCALENDAR\r
                    """, range: range
            ).first)
        #expect(event.title == "Plan, review; ship")
        #expect(event.details == "Line one\nJoin https://zoom.us/j/12345")
        #expect(event.location == "Room 4")
        #expect(event.organizer == "boss@example.com")
        #expect(event.meetingURL == "https://zoom.us/j/12345")
    }

    @Test func tzidIsHonoured() throws {
        let event = try #require(one("DTSTART;TZID=America/New_York:20260923T100000\r\nDTEND;TZID=America/New_York:20260923T110000\r\n"))
        #expect(event.start == utc("2026-09-23T14:00:00Z"))
    }

    @Test func windowsZoneNamesResolve() throws {
        let event = try #require(one("DTSTART;TZID=\"Pacific Standard Time\":20260923T100000\r\n"))
        #expect(event.start == utc("2026-09-23T17:00:00Z"))
    }

    @Test func customVTimezoneFallsBackToItsOffset() throws {
        let data = """
            BEGIN:VCALENDAR\r
            BEGIN:VTIMEZONE\r
            TZID:Corp Time\r
            BEGIN:STANDARD\r
            DTSTART:19700101T000000\r
            TZOFFSETFROM:+0300\r
            TZOFFSETTO:+0300\r
            END:STANDARD\r
            END:VTIMEZONE\r
            BEGIN:VEVENT\r
            UID:tz\r
            DTSTART;TZID=Corp Time:20260923T100000\r
            END:VEVENT\r
            END:VCALENDAR\r
            """
        let event = try #require(parser.meetings(from: data, range: range).first)
        #expect(event.start == utc("2026-09-23T07:00:00Z"))
    }

    @Test func everyVEventInAResourceIsReturned() {
        let data = """
            BEGIN:VCALENDAR\r
            BEGIN:VEVENT\r
            UID:r\r
            RECURRENCE-ID:20260923T100000Z\r
            DTSTART:20260923T100000Z\r
            SUMMARY:A\r
            END:VEVENT\r
            BEGIN:VEVENT\r
            UID:r\r
            RECURRENCE-ID:20260924T100000Z\r
            DTSTART:20260924T100000Z\r
            SUMMARY:A\r
            END:VEVENT\r
            END:VCALENDAR\r
            """
        #expect(parser.meetings(from: data, range: range).count == 2)
    }

    @Test func durations() {
        #expect(ICalendar.duration("PT45M") == 2700)
        #expect(ICalendar.duration("P1DT2H") == 93_600)
        #expect(ICalendar.duration("P1W") == 604_800)
        #expect(ICalendar.duration("-PT15M") == -900)
        #expect(ICalendar.duration("garbage") == nil)
    }
}

@Suite struct RecurrenceTests {
    let parser = EventParser(ownAddress: "me@example.com")

    func expand(
        _ rule: String, start: String = "DTSTART:20260901T090000Z\r\nDTEND:20260901T093000Z\r\n", extra: String = "",
        from: String, to: String
    ) -> [Date] {
        let data =
            "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r\r\nSUMMARY:Daily\r\n\(start)RRULE:\(rule)\r\n\(extra)END:VEVENT\r\n\(overrides)END:VCALENDAR\r\n"
        return parser.meetings(from: data, range: DateInterval(start: utc(from), end: utc(to))).map(\.start)
    }

    var overrides = ""

    @Test func dailyInsideTheWindowOnly() {
        let starts = expand("FREQ=DAILY", from: "2026-09-22T00:00:00Z", to: "2026-09-25T00:00:00Z")
        #expect(starts == [utc("2026-09-22T09:00:00Z"), utc("2026-09-23T09:00:00Z"), utc("2026-09-24T09:00:00Z")])
    }

    @Test func weeklyByDayWithInterval() {
        let starts = expand("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH", from: "2026-09-01T00:00:00Z", to: "2026-09-30T00:00:00Z")
        #expect(starts.map { Calendar.utc.component(.day, from: $0) } == [1, 3, 15, 17, 29])
    }

    @Test func countLimitsOccurrences() {
        let starts = expand("FREQ=DAILY;COUNT=3", from: "2026-08-01T00:00:00Z", to: "2026-10-01T00:00:00Z")
        #expect(starts.count == 3)
    }

    @Test func untilIsInclusive() {
        let starts = expand("FREQ=DAILY;UNTIL=20260903T090000Z", from: "2026-08-01T00:00:00Z", to: "2026-10-01T00:00:00Z")
        #expect(starts.count == 3)
    }

    @Test func monthlyLastFridayViaBySetPos() {
        let starts = expand("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", from: "2026-09-01T00:00:00Z", to: "2026-11-01T00:00:00Z")
        #expect(starts == [utc("2026-09-30T09:00:00Z"), utc("2026-10-30T09:00:00Z")])
    }

    @Test func monthlyNthWeekday() {
        let starts = expand("FREQ=MONTHLY;BYDAY=2WE", from: "2026-09-01T00:00:00Z", to: "2026-12-01T00:00:00Z")
        #expect(starts.map { Calendar.utc.component(.day, from: $0) } == [9, 14, 11])
    }

    @Test func exdateAndOverridesRemoveOccurrences() {
        var test = self
        test.overrides = "BEGIN:VEVENT\r\nUID:r\r\nRECURRENCE-ID:20260923T090000Z\r\nDTSTART:20260923T150000Z\r\nSUMMARY:Moved\r\nEND:VEVENT\r\n"
        let starts = test.expand("FREQ=DAILY", extra: "EXDATE:20260922T090000Z\r\n", from: "2026-09-21T00:00:00Z", to: "2026-09-25T00:00:00Z")
        #expect(
            starts.sorted() == [
                utc("2026-09-21T09:00:00Z"), utc("2026-09-23T15:00:00Z"), utc("2026-09-24T09:00:00Z"),
            ])
    }

    @Test func wallClockTimeSurvivesDaylightSaving() {
        let starts = expand(
            "FREQ=WEEKLY",
            start: "DTSTART;TZID=Europe/Kyiv:20261019T100000\r\nDTEND;TZID=Europe/Kyiv:20261019T103000\r\n",
            from: "2026-10-18T00:00:00Z", to: "2026-10-28T00:00:00Z")
        #expect(starts == [utc("2026-10-19T07:00:00Z"), utc("2026-10-26T08:00:00Z")])
    }

    @Test func ongoingOccurrenceStartingBeforeTheWindowIsKept() {
        let starts = expand("FREQ=DAILY", from: "2026-09-22T09:15:00Z", to: "2026-09-22T12:00:00Z")
        #expect(starts == [utc("2026-09-22T09:00:00Z")])
    }
}

extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
