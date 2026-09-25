import Foundation

public enum DNDDuration: String, CaseIterable, Sendable {
    case thirtyMinutes = "30min"
    case oneHour = "1hour"
    case threeHours = "3hours"
    case fiveHours = "5hours"
    case twelveHours = "12hours"
    case untilResume = "until_resume"

    public var minutes: Int? {
        switch self {
        case .thirtyMinutes: 30
        case .oneHour: 60
        case .threeHours: 180
        case .fiveHours: 300
        case .twelveHours: 720
        case .untilResume: nil
        }
    }

    public var label: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .threeHours: "3 hours"
        case .fiveHours: "5 hours"
        case .twelveHours: "12 hours"
        case .untilResume: "Until I resume"
        }
    }
}

public struct DNDState: Equatable, Sendable {
    public private(set) var enabled = false
    public private(set) var duration: DNDDuration?
    public private(set) var startTime: Date?
    public private(set) var endTime: Date?

    public init() {}

    public mutating func start(_ duration: DNDDuration, at now: Date) {
        enabled = true
        self.duration = duration
        startTime = now
        endTime = duration.minutes.map { now.addingTimeInterval(Double($0) * 60) }
    }

    public mutating func stop() {
        self = DNDState()
    }

    public func isActive(at now: Date) -> Bool {
        guard enabled else { return false }
        if duration == .untilResume { return true }
        guard let endTime else { return false }
        return now < endTime
    }

    public func remaining(at now: Date) -> TimeInterval? {
        guard isActive(at: now), duration != .untilResume, let endTime else { return nil }
        return max(0, endTime.timeIntervalSince(now))
    }

    public func elapsed(at now: Date) -> TimeInterval? {
        startTime.map { now.timeIntervalSince($0) }
    }

    /// Short human status such as "42m left" or "until resumed".
    public func summary(at now: Date) -> String? {
        guard isActive(at: now) else { return nil }
        if duration == .untilResume { return "until you resume" }
        return remaining(at: now).map { "\(Formatting.shortDuration($0)) left" }
    }
}
