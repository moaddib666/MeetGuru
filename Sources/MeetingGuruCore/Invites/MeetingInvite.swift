import Foundation

public enum InviteResponse: String, CaseIterable, Sendable {
    case accepted = "ACCEPTED"
    case tentative = "TENTATIVE"
    case declined = "DECLINED"

    public var label: String {
        switch self {
        case .accepted: "Accept"
        case .tentative: "Maybe"
        case .declined: "Decline"
        }
    }

    public var confirmation: String {
        switch self {
        case .accepted: "Accepted"
        case .tentative: "Marked as maybe"
        case .declined: "Declined"
        }
    }
}

/// A meeting someone else organised that is still waiting for this user's answer.
public struct MeetingInvite: Sendable, Hashable, Identifiable {
    /// Changes when the organiser reschedules, so a moved meeting is announced again.
    public var id: String
    /// The next occurrence that still needs an answer.
    public var meeting: MeetingEvent
    public var organizerName: String?
    public var isRecurring: Bool
    public var resource: URL
    public var etag: String?
    public var calendarData: String

    public init(
        id: String, meeting: MeetingEvent, organizerName: String? = nil, isRecurring: Bool = false,
        resource: URL, etag: String? = nil, calendarData: String = ""
    ) {
        self.id = id
        self.meeting = meeting
        self.organizerName = organizerName
        self.isRecurring = isRecurring
        self.resource = resource
        self.etag = etag
        self.calendarData = calendarData
    }

    public var from: String? { organizerName ?? meeting.organizer }
}

/// Finds pending invitations in raw calendar resources: events with an organiser other than
/// the user where the user's ATTENDEE line is NEEDS-ACTION (the RFC 5545 default).
public struct InviteDetector: Sendable {
    public var addresses: Set<String>
    public var localZone: TimeZone

    public init(addresses: Set<String>, localZone: TimeZone = .current) {
        self.addresses = Set(addresses.map { EventParser.stripMailto($0).lowercased() }.filter { !$0.isEmpty })
        self.localZone = localZone
    }

    public func invite(resource: URL, etag: String?, calendarData: String, now: Date, until: Date) -> MeetingInvite? {
        guard !addresses.isEmpty else { return nil }
        let parser = EventParser(ownAddress: "", localZone: localZone)
        for calendar in ICalendar.parse(calendarData) where calendar.name == "VCALENDAR" {
            let zones = TimeZoneResolver(calendar: calendar)
            let pending = calendar.children.filter { $0.name == "VEVENT" && awaitsAnswer($0) }
            guard !pending.isEmpty else { continue }

            let master = pending.first { $0.first("RECURRENCE-ID") == nil }
            let upcoming: MeetingEvent?
            if master?.first("RRULE") != nil {
                upcoming = parser.meetings(from: calendarData, range: DateInterval(start: now, end: max(now, until)))
                    .filter { $0.end > now }.min { $0.start < $1.start }
            } else {
                upcoming = pending.compactMap { parser.meeting(from: $0, zones: zones) }
                    .filter { $0.end > now && $0.start < until }.min { $0.start < $1.start }
            }
            guard let upcoming, let anchor = master ?? pending.first else { continue }

            let identity = [
                anchor.first("UID")?.value ?? resource.absoluteString,
                anchor.first("RECURRENCE-ID")?.value ?? "",
                anchor.first("SEQUENCE")?.value ?? "0",
                anchor.first("DTSTART")?.value ?? "",
            ]
            let organizerName = anchor.first("ORGANIZER")?.params["CN"].flatMap { $0.isEmpty ? nil : $0 }
            return MeetingInvite(
                id: identity.joined(separator: "|"),
                meeting: upcoming,
                organizerName: organizerName,
                isRecurring: master?.first("RRULE") != nil,
                resource: resource,
                etag: etag,
                calendarData: calendarData)
        }
        return nil
    }

    func awaitsAnswer(_ vevent: ICalComponent) -> Bool {
        if vevent.first("STATUS")?.value.uppercased() == "CANCELLED" { return false }
        guard let organizer = vevent.first("ORGANIZER"), !isOwn(organizer.value) else { return false }
        return vevent.all("ATTENDEE").contains { attendee in
            isOwn(attendee.value) && (attendee.params["PARTSTAT"]?.uppercased() ?? "NEEDS-ACTION") == "NEEDS-ACTION"
        }
    }

    func isOwn(_ address: String) -> Bool {
        addresses.contains(EventParser.stripMailto(address).lowercased())
    }
}

extension ICalendar {
    /// The resource with the user's PARTSTAT set on every event's own ATTENDEE line, ready to PUT back.
    /// Other lines are kept verbatim; returns nil when the user is not an attendee.
    public static func answering(_ response: InviteResponse, as addresses: Set<String>, in calendarData: String) -> String? {
        let own = Set(addresses.map { EventParser.stripMailto($0).lowercased() })
        var stack: [String] = []
        var changed = false
        var output: [String] = []
        for line in unfold(calendarData) {
            let property = parseLine(line)
            switch property?.name {
            case "BEGIN": stack.append(property!.value.uppercased())
            case "END": _ = stack.popLast()
            case "ATTENDEE" where stack.last == "VEVENT":
                if let property, own.contains(EventParser.stripMailto(property.value).lowercased()),
                    let rewritten = settingParameter("PARTSTAT", to: response.rawValue, in: line)
                {
                    output.append(rewritten)
                    changed = true
                    continue
                }
            default: break
            }
            output.append(line)
        }
        guard changed else { return nil }
        return output.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// Replaces (or adds) one parameter, keeping the others exactly as written.
    static func settingParameter(_ name: String, to value: String, in line: String) -> String? {
        var inQuotes = false
        var segments: [String] = []
        var current = ""
        var remainder: Substring?
        for (index, character) in zip(line.indices, line) {
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes, character == ";" || character == ":" {
                segments.append(current)
                current = ""
                if character == ":" {
                    remainder = line[line.index(after: index)...]
                    break
                }
                continue
            }
            current.append(character)
        }
        guard let remainder, let propertyName = segments.first else { return nil }
        let prefix = name.uppercased() + "="
        let kept = segments.dropFirst().filter { !$0.uppercased().hasPrefix(prefix) }
        return ([propertyName] + kept + [prefix + value]).joined(separator: ";") + ":" + remainder
    }

    /// RFC 5545 line folding: at most 75 octets per line, never splitting a UTF-8 character.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var lines: [String] = []
        var current = ""
        var octets = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = lines.isEmpty ? 75 : 74
            if octets + size > limit {
                lines.append(current)
                current = ""
                octets = 0
            }
            current.append(character)
            octets += size
        }
        lines.append(current)
        return lines.joined(separator: "\r\n ")
    }
}
