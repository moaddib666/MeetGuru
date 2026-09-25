import Foundation

/// Turns calendar-object resources into meetings, matching the Python connector's rules:
/// cancelled events and events the user declined are dropped, times become absolute instants.
public struct EventParser: Sendable {
    public static let conferenceProperties = ["CONFERENCE", "X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL"]

    public var ownAddress: String
    public var localZone: TimeZone

    public init(ownAddress: String, localZone: TimeZone = .current) {
        self.ownAddress = ownAddress.lowercased()
        self.localZone = localZone
    }

    /// All meetings in one resource; recurring masters are expanded inside `range`.
    public func meetings(from calendarData: String, range: DateInterval) -> [MeetingEvent] {
        var result: [MeetingEvent] = []
        for calendar in ICalendar.parse(calendarData) where calendar.name == "VCALENDAR" {
            let zones = TimeZoneResolver(calendar: calendar)
            let vevents = calendar.children.filter { $0.name == "VEVENT" }
            let overrides = vevents.filter { $0.first("RECURRENCE-ID") != nil }
            let overriddenStarts = Set(
                overrides.compactMap { vevent in
                    vevent.first("RECURRENCE-ID").flatMap { ICalendar.date($0, zones: zones, fallbackZone: localZone)?.date }
                })
            for vevent in vevents {
                if vevent.first("RRULE") != nil && vevent.first("RECURRENCE-ID") == nil {
                    result += expand(vevent, zones: zones, range: range, skipping: overriddenStarts)
                } else if let meeting = meeting(from: vevent, zones: zones) {
                    result.append(meeting)
                }
            }
        }
        return result
    }

    public func meeting(from vevent: ICalComponent, zones: TimeZoneResolver) -> MeetingEvent? {
        if vevent.first("STATUS")?.value.uppercased() == "CANCELLED" { return nil }
        guard let startProperty = vevent.first("DTSTART"),
            let parsedStart = ICalendar.date(startProperty, zones: zones, fallbackZone: localZone)
        else { return nil }

        let start = parsedStart.date
        let end = start.addingTimeInterval(eventDuration(vevent, start: parsedStart, zones: zones))

        var attendees: [String] = []
        for property in vevent.all("ATTENDEE") {
            let address = Self.stripMailto(property.value)
            if !ownAddress.isEmpty, address.lowercased() == ownAddress,
                property.params["PARTSTAT"]?.uppercased() == "DECLINED"
            {
                return nil
            }
            attendees.append(address)
        }

        return MeetingEvent(
            uid: vevent.first("UID")?.value ?? "",
            title: vevent.first("SUMMARY")?.text ?? "Untitled",
            start: start,
            end: end,
            location: nonEmpty(vevent.first("LOCATION")?.text),
            details: nonEmpty(vevent.first("DESCRIPTION")?.text),
            url: nonEmpty(vevent.first("URL")?.value),
            organizer: vevent.first("ORGANIZER").map { Self.stripMailto($0.value) },
            attendees: attendees,
            allDay: parsedStart.isDateOnly,
            conferenceURLs: Self.conferenceProperties.flatMap { vevent.all($0).map(\.value) }
        )
    }

    private func expand(_ master: ICalComponent, zones: TimeZoneResolver, range: DateInterval, skipping overridden: Set<Date>) -> [MeetingEvent] {
        guard let startProperty = master.first("DTSTART"),
            let start = ICalendar.date(startProperty, zones: zones, fallbackZone: localZone),
            let template = meeting(from: master, zones: zones)
        else { return [] }
        let duration = eventDuration(master, start: start, zones: zones)
        let excluded = Set(master.all("EXDATE").flatMap { ICalendar.dates($0, zones: zones, fallbackZone: localZone).map(\.date) })

        var starts = Set<Date>()
        for rule in master.all("RRULE").compactMap({ RecurrenceRule($0.value) }) {
            starts.formUnion(
                rule.occurrences(
                    start: start, duration: duration, rangeStart: range.start, rangeEnd: range.end, zones: zones))
        }
        for rdate in master.all("RDATE").flatMap({ ICalendar.dates($0, zones: zones, fallbackZone: localZone) })
        where rdate.date < range.end && rdate.date.addingTimeInterval(max(duration, 1)) > range.start {
            starts.insert(rdate.date)
        }
        return starts.subtracting(excluded).subtracting(overridden).sorted().map { occurrence in
            var meeting = template
            meeting.start = occurrence
            meeting.end = occurrence.addingTimeInterval(duration)
            return meeting
        }
    }

    private func eventDuration(_ vevent: ICalComponent, start: ICalDate, zones: TimeZoneResolver) -> TimeInterval {
        if let endProperty = vevent.first("DTEND"),
            let end = ICalendar.date(endProperty, zones: zones, fallbackZone: localZone)
        {
            return end.date.timeIntervalSince(start.date)
        }
        if let raw = vevent.first("DURATION")?.value, let duration = ICalendar.duration(raw) {
            return duration
        }
        return start.isDateOnly ? 86_400 : 3_600
    }

    static func stripMailto(_ value: String) -> String {
        value.lowercased().hasPrefix("mailto:") ? String(value.dropFirst(7)) : value
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
