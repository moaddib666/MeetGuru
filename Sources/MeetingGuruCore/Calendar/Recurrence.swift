import Foundation

/// RFC 5545 RRULE subset: DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL,
/// BYDAY (incl. ordinals), BYMONTHDAY, BYMONTH, BYSETPOS and WKST.
public struct RecurrenceRule: Equatable, Sendable {
    public enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    public struct WeekdayRule: Equatable, Sendable {
        public var weekday: Int
        public var ordinal: Int?
    }

    public var frequency: Frequency
    public var interval = 1
    public var count: Int?
    public var until: String?
    public var byDay: [WeekdayRule] = []
    public var byMonthDay: [Int] = []
    public var byMonth: [Int] = []
    public var bySetPos: [Int] = []
    public var weekStart = 2

    private static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    public init?(_ raw: String) {
        var parts: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
        }
        guard let frequency = parts["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }) else { return nil }
        self.frequency = frequency
        interval = max(1, Int(parts["INTERVAL"] ?? "") ?? 1)
        count = parts["COUNT"].flatMap { Int($0) }
        until = parts["UNTIL"]
        byMonthDay = Self.integers(parts["BYMONTHDAY"])
        byMonth = Self.integers(parts["BYMONTH"])
        bySetPos = Self.integers(parts["BYSETPOS"])
        weekStart = parts["WKST"].flatMap { Self.weekdays[$0.uppercased()] } ?? 2
        byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { token in
            let text = token.trimmingCharacters(in: .whitespaces).uppercased()
            guard text.count >= 2, let weekday = Self.weekdays[String(text.suffix(2))] else { return nil }
            let prefix = text.dropLast(2)
            return WeekdayRule(weekday: weekday, ordinal: prefix.isEmpty ? nil : Int(prefix))
        }
    }

    private static func integers(_ raw: String?) -> [Int] {
        (raw ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Occurrence starts overlapping `[rangeStart, rangeEnd)` for an event of `duration`.
    public func occurrences(
        start: ICalDate, duration: TimeInterval, rangeStart: Date, rangeEnd: Date, zones: TimeZoneResolver, maxPeriods: Int = 100_000
    ) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = start.timeZone
        calendar.firstWeekday = weekStart
        let untilDate = until.flatMap { value -> Date? in
            guard let parsed = ICalendar.parseDateTime(value, zone: start.timeZone, forceDate: false) else { return nil }
            return parsed.isDateOnly ? calendar.date(byAdding: DateComponents(day: 1, second: -1), to: parsed.date) : parsed.date
        }
        let time = calendar.dateComponents([.hour, .minute, .second], from: start.date)
        let anchor = calendar.dateComponents([.year, .month, .day, .weekday], from: start.date)

        var results: [Date] = []
        var emitted = 0
        for period in 0..<maxPeriods {
            let step = period * interval
            var candidates = candidatesFor(step: step, anchor: anchor, calendar: calendar)
                .compactMap { day -> Date? in
                    var components = day
                    components.hour = time.hour
                    components.minute = time.minute
                    components.second = time.second
                    return calendar.date(from: components)
                }
                .sorted()
            candidates = applySetPos(candidates)
            for candidate in candidates where candidate >= start.date {
                if let untilDate, candidate > untilDate { return results }
                if let count, emitted >= count { return results }
                emitted += 1
                if candidate >= rangeEnd { return results }
                if candidate.addingTimeInterval(max(duration, 1)) > rangeStart { results.append(candidate) }
            }
            if let periodStart = candidates.first, periodStart >= rangeEnd { return results }
            if let firstDay = candidatesFor(step: step, anchor: anchor, calendar: calendar, filtered: false).first,
                let date = calendar.date(from: firstDay), date > rangeEnd, candidates.isEmpty
            {
                return results
            }
        }
        return results
    }

    private func applySetPos(_ sorted: [Date]) -> [Date] {
        guard !bySetPos.isEmpty, !sorted.isEmpty else { return sorted }
        let picked = bySetPos.compactMap { position -> Date? in
            let index = position > 0 ? position - 1 : sorted.count + position
            return sorted.indices.contains(index) ? sorted[index] : nil
        }
        return Array(Set(picked)).sorted()
    }

    private func candidatesFor(step: Int, anchor: DateComponents, calendar: Calendar, filtered: Bool = true) -> [DateComponents] {
        switch frequency {
        case .daily:
            guard let base = calendar.date(from: DateComponents(year: anchor.year, month: anchor.month, day: anchor.day)),
                let day = calendar.date(byAdding: .day, value: step, to: base)
            else { return [] }
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if filtered {
                if !byMonth.isEmpty, !byMonth.contains(components.month!) { return [] }
                if !byMonthDay.isEmpty, !matchesMonthDay(components, calendar: calendar) { return [] }
                if !byDay.isEmpty, !byDay.contains(where: { $0.weekday == components.weekday }) { return [] }
            }
            return [components]

        case .weekly:
            guard let base = calendar.date(from: DateComponents(year: anchor.year, month: anchor.month, day: anchor.day)),
                let weekStartDate = calendar.dateInterval(of: .weekOfYear, for: base)?.start,
                let week = calendar.date(byAdding: .weekOfYear, value: step, to: weekStartDate)
            else { return [] }
            let weekdays = byDay.isEmpty ? [anchor.weekday!] : byDay.map(\.weekday)
            return (0..<7).compactMap { offset -> DateComponents? in
                guard let day = calendar.date(byAdding: .day, value: offset, to: week) else { return nil }
                let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                guard weekdays.contains(components.weekday!) else { return nil }
                if filtered, !byMonth.isEmpty, !byMonth.contains(components.month!) { return nil }
                return components
            }

        case .monthly:
            guard let base = calendar.date(from: DateComponents(year: anchor.year, month: anchor.month, day: 1)),
                let month = calendar.date(byAdding: .month, value: step, to: base)
            else { return [] }
            let components = calendar.dateComponents([.year, .month], from: month)
            if filtered, !byMonth.isEmpty, !byMonth.contains(components.month!) { return [] }
            return daysInMonth(year: components.year!, month: components.month!, anchorDay: anchor.day!, calendar: calendar)

        case .yearly:
            let year = anchor.year! + step
            let months = byMonth.isEmpty ? [anchor.month!] : byMonth
            return months.flatMap { daysInMonth(year: year, month: $0, anchorDay: anchor.day!, calendar: calendar) }
        }
    }

    private func daysInMonth(year: Int, month: Int, anchorDay: Int, calendar: Calendar) -> [DateComponents] {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
            let length = calendar.range(of: .day, in: .month, for: first)?.count
        else { return [] }
        let all = (1...length).map { day -> DateComponents in
            let date = calendar.date(byAdding: .day, value: day - 1, to: first)!
            return calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        }
        if byMonthDay.isEmpty && byDay.isEmpty {
            return anchorDay <= length ? [all[anchorDay - 1]] : []
        }
        var days = all
        if !byMonthDay.isEmpty {
            let wanted = Set(byMonthDay.map { $0 > 0 ? $0 : length + $0 + 1 })
            days = days.filter { wanted.contains($0.day!) }
        }
        if !byDay.isEmpty {
            days = days.filter { components in
                byDay.contains { rule in
                    guard rule.weekday == components.weekday else { return false }
                    guard let ordinal = rule.ordinal else { return true }
                    let sameWeekday = all.filter { $0.weekday == rule.weekday }
                    let index = ordinal > 0 ? ordinal - 1 : sameWeekday.count + ordinal
                    return sameWeekday.indices.contains(index) && sameWeekday[index].day == components.day
                }
            }
        }
        return days
    }

    private func matchesMonthDay(_ components: DateComponents, calendar: Calendar) -> Bool {
        guard let date = calendar.date(from: components),
            let length = calendar.range(of: .day, in: .month, for: date)?.count
        else { return false }
        return byMonthDay.map { $0 > 0 ? $0 : length + $0 + 1 }.contains(components.day!)
    }
}
