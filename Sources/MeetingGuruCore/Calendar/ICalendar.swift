import Foundation

public struct ICalProperty: Equatable, Sendable {
    public var name: String
    public var params: [String: String]
    public var value: String

    public var text: String { ICalendar.unescape(value) }
}

public struct ICalComponent: Equatable, Sendable {
    public var name: String
    public var properties: [ICalProperty] = []
    public var children: [ICalComponent] = []

    public func first(_ name: String) -> ICalProperty? { properties.first { $0.name == name } }

    public func all(_ name: String) -> [ICalProperty] { properties.filter { $0.name == name } }

    public func components(named name: String) -> [ICalComponent] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.components(named: name) }
    }
}

/// A DTSTART-style value resolved to an instant, keeping the zone it repeats in.
public struct ICalDate: Equatable, Sendable {
    public var date: Date
    public var isDateOnly: Bool
    public var timeZone: TimeZone
}

public enum ICalendar {
    /// Parses a VCALENDAR stream into its top-level components.
    public static func parse(_ text: String) -> [ICalComponent] {
        var stack: [ICalComponent] = []
        var roots: [ICalComponent] = []
        for line in unfold(text) {
            guard let property = parseLine(line) else { continue }
            switch property.name {
            case "BEGIN":
                stack.append(ICalComponent(name: property.value.uppercased()))
            case "END":
                guard let done = stack.popLast() else { continue }
                if stack.isEmpty { roots.append(done) } else { stack[stack.count - 1].children.append(done) }
            default:
                if !stack.isEmpty { stack[stack.count - 1].properties.append(property) }
            }
        }
        return roots
    }

    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    static func parseLine(_ line: String) -> ICalProperty? {
        var inQuotes = false
        var segments: [String] = []
        var current = ""
        var value: String?
        for (offset, character) in line.enumerated() {
            if character == "\"" { inQuotes.toggle(); current.append(character); continue }
            if !inQuotes && character == ";" { segments.append(current); current = ""; continue }
            if !inQuotes && character == ":" {
                segments.append(current)
                value = String(line.dropFirst(offset + 1))
                break
            }
            current.append(character)
        }
        guard let value, let name = segments.first, !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return ICalProperty(name: name.uppercased(), params: params, value: value)
    }

    public static func unescape(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    /// Parses DATE / DATE-TIME values; floating times and dates land in `fallbackZone`.
    public static func date(_ property: ICalProperty, zones: TimeZoneResolver, fallbackZone: TimeZone = .current) -> ICalDate? {
        dates(property, zones: zones, fallbackZone: fallbackZone).first
    }

    public static func dates(_ property: ICalProperty, zones: TimeZoneResolver, fallbackZone: TimeZone = .current) -> [ICalDate] {
        let zone = property.params["TZID"].flatMap(zones.resolve) ?? fallbackZone
        let forceDate = property.params["VALUE"]?.uppercased() == "DATE"
        return property.value.split(separator: ",").compactMap { part in
            let raw = part.split(separator: "/").first.map(String.init) ?? ""
            return parseDateTime(raw.trimmingCharacters(in: .whitespaces), zone: zone, forceDate: forceDate)
        }
    }

    static func parseDateTime(_ raw: String, zone: TimeZone, forceDate: Bool) -> ICalDate? {
        let digits = raw.uppercased()
        let isDateOnly = forceDate || !digits.contains("T")
        let utc = digits.hasSuffix("Z")
        let body = utc ? String(digits.dropLast()) : digits
        var components = DateComponents()
        let chars = Array(body)
        func number(_ start: Int, _ length: Int) -> Int? {
            guard chars.count >= start + length else { return nil }
            return Int(String(chars[start..<start + length]))
        }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2) else { return nil }
        components.year = year
        components.month = month
        components.day = day
        if isDateOnly {
            components.hour = 0
        } else {
            guard chars.count >= 13, chars[8] == "T", let hour = number(9, 2), let minute = number(11, 2) else { return nil }
            components.hour = hour
            components.minute = minute
            components.second = number(13, 2) ?? 0
        }
        let effectiveZone = utc ? TimeZone(identifier: "UTC")! : zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = effectiveZone
        guard let date = calendar.date(from: components) else { return nil }
        return ICalDate(date: date, isDateOnly: isDateOnly, timeZone: effectiveZone)
    }

    /// RFC 5545 DURATION such as "PT45M", "-P1D" or "P1W".
    public static func duration(_ raw: String) -> TimeInterval? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces).uppercased())
        var sign: Double = 1
        if text.first == "-" { sign = -1; text = text.dropFirst() } else if text.first == "+" { text = text.dropFirst() }
        guard text.first == "P" else { return nil }
        text = text.dropFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        var parsedAny = false
        for character in text {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let value = Double(number) else { return nil }
            number = ""
            parsedAny = true
            switch (character, inTime) {
            case ("W", false): total += value * 604_800
            case ("D", false): total += value * 86_400
            case ("H", true): total += value * 3_600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            default: return nil
            }
        }
        return parsedAny && number.isEmpty ? sign * total : nil
    }
}

/// Resolves TZIDs: IANA names, common Windows names, then the calendar's own VTIMEZONE offsets.
public struct TimeZoneResolver: Sendable {
    private var custom: [String: TimeZone] = [:]

    public init(calendar: ICalComponent? = nil) {
        guard let calendar else { return }
        for vtimezone in calendar.components(named: "VTIMEZONE") {
            guard let tzid = vtimezone.first("TZID")?.value else { continue }
            if let zone = Self.named(tzid) {
                custom[tzid] = zone
                continue
            }
            let standard = vtimezone.children.first { $0.name == "STANDARD" } ?? vtimezone.children.first
            if let offset = standard?.first("TZOFFSETTO")?.value, let seconds = Self.offsetSeconds(offset),
                let zone = TimeZone(secondsFromGMT: seconds)
            {
                custom[tzid] = zone
            }
        }
    }

    public func resolve(_ tzid: String) -> TimeZone? {
        custom[tzid] ?? Self.named(tzid)
    }

    static func named(_ tzid: String) -> TimeZone? {
        let trimmed = tzid.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let zone = TimeZone(identifier: trimmed) { return zone }
        if let mapped = windowsZones[trimmed], let zone = TimeZone(identifier: mapped) { return zone }
        let parts = trimmed.split(separator: "/")
        for start in parts.indices.dropFirst() {
            if let zone = TimeZone(identifier: parts[start...].joined(separator: "/")) { return zone }
        }
        return nil
    }

    static func offsetSeconds(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let signChar = text.first, signChar == "+" || signChar == "-" else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.count >= 4, let hours = Int(String(digits[0..<2])), let minutes = Int(String(digits[2..<4])) else { return nil }
        let seconds = digits.count >= 6 ? Int(String(digits[4..<6])) ?? 0 : 0
        let total = hours * 3600 + minutes * 60 + seconds
        return signChar == "-" ? -total : total
    }

    static let windowsZones: [String: String] = [
        "UTC": "UTC", "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw", "Romance Standard Time": "Europe/Paris",
        "FLE Standard Time": "Europe/Kyiv", "GTB Standard Time": "Europe/Bucharest",
        "E. Europe Standard Time": "Europe/Chisinau", "Turkey Standard Time": "Europe/Istanbul",
        "Israel Standard Time": "Asia/Jerusalem", "Russian Standard Time": "Europe/Moscow",
        "Arabian Standard Time": "Asia/Dubai", "India Standard Time": "Asia/Kolkata",
        "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore",
        "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
        "AUS Eastern Standard Time": "Australia/Sydney", "New Zealand Standard Time": "Pacific/Auckland",
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax",
        "E. South America Standard Time": "America/Sao_Paulo", "SA Pacific Standard Time": "America/Bogota",
        "Mexico Standard Time": "America/Mexico_City", "Canada Central Standard Time": "America/Regina",
    ]
}
