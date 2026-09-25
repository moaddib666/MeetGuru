import Foundation

public enum AppState: String, Sendable {
    case initializing
    case idle
    case alertPending = "alert_pending"
    case alertShowing = "alert_showing"
    case meetingActive = "meeting_active"
    case error
}

public struct StateContext: Sendable {
    public var currentMeeting: MeetingEvent?
    public var alertStatus: AlertStatus = .pending
    public var alertShownAt: Date?
    public var acknowledged: Set<String> = []
    public var alerted: Set<String> = []
    public var autoJoined: Set<String> = []
    public var lastSyncTime: Date?
}

/// Decides which meeting needs attention and tracks what the user did about it.
///
/// Every meeting is tracked by fingerprint, so overlapping meetings are handled
/// independently: the meeting whose alert window opened most recently takes the
/// alert, and one the user has acknowledged or joined never comes back.
public final class StateMachine {
    public private(set) var state: AppState = .initializing
    public var context = StateContext()
    public var onTransition: ((AppState, AppState) -> Void)?

    public init() {}

    public func initializeComplete() { transition(to: .idle) }

    public func selectMeeting(from events: [MeetingEvent], alertAdvanceMinutes: Int, now: Date) -> MeetingEvent? {
        let window = Double(alertAdvanceMinutes * 60)
        let currentFingerprint = context.currentMeeting?.fingerprint
        let candidates = events.filter { meeting in
            if meeting.allDay || meeting.status(at: now) == .completed { return false }
            if meeting.timeToStart(at: now) > window { return false }
            let fingerprint = meeting.fingerprint
            if context.acknowledged.contains(fingerprint) { return false }
            if context.autoJoined.contains(fingerprint), fingerprint != currentFingerprint { return false }
            return true
        }
        return candidates.max { $0.start < $1.start }
    }

    /// Returns true when the meeting needing attention changed.
    @discardableResult
    public func setCurrentMeeting(_ meeting: MeetingEvent?) -> Bool {
        let oldFingerprint = context.currentMeeting?.fingerprint
        let newFingerprint = meeting?.fingerprint
        context.currentMeeting = meeting
        guard oldFingerprint != newFingerprint else { return false }

        context.alertStatus = .pending
        context.alertShownAt = nil
        if let meeting {
            Log.info("Meeting needing attention: \(meeting.title) at \(meeting.start)")
            transition(to: .alertPending)
        } else if [.alertPending, .alertShowing, .meetingActive].contains(state) {
            transition(to: .idle)
        }
        return true
    }

    public var shouldShowAlert: Bool {
        guard let meeting = context.currentMeeting else { return false }
        if context.acknowledged.contains(meeting.fingerprint) { return false }
        return context.alertStatus != .showing && context.alertStatus != .dismissed
    }

    /// Marks the alert as showing. Returns true the first time this meeting is alerted.
    @discardableResult
    public func showAlert(at now: Date) -> Bool {
        guard let meeting = context.currentMeeting else { return false }
        let firstTime = context.alerted.insert(meeting.fingerprint).inserted
        context.alertStatus = .showing
        context.alertShownAt = now
        transition(to: .alertShowing)
        return firstTime
    }

    public func acknowledge(_ fingerprint: String) {
        context.acknowledged.insert(fingerprint)
        if isCurrent(fingerprint) {
            context.alertStatus = .dismissed
            transition(to: .idle)
        }
        Log.info("Meeting acknowledged: \(fingerprint)")
    }

    public func participate(_ fingerprint: String) {
        context.acknowledged.insert(fingerprint)
        if isCurrent(fingerprint) {
            context.alertStatus = .autoJoined
            transition(to: .meetingActive)
        }
        Log.info("Meeting participated: \(fingerprint)")
    }

    public func shouldAutoParticipate(delaySeconds: Int, now: Date) -> Bool {
        guard let meeting = context.currentMeeting, state == .alertShowing,
            let shownAt = context.alertShownAt
        else { return false }
        let fingerprint = meeting.fingerprint
        if context.autoJoined.contains(fingerprint) || context.acknowledged.contains(fingerprint) { return false }
        return now.timeIntervalSince(shownAt) >= Double(delaySeconds)
    }

    public func markAutoJoined(_ fingerprint: String) { context.autoJoined.insert(fingerprint) }

    public func isAutoJoined(_ meeting: MeetingEvent) -> Bool { context.autoJoined.contains(meeting.fingerprint) }

    public func isAcknowledged(_ meeting: MeetingEvent) -> Bool { context.acknowledged.contains(meeting.fingerprint) }

    /// Drops tracking for meetings no longer present in the calendar.
    public func forgetMissing(_ known: [MeetingEvent]) {
        let fingerprints = Set(known.map(\.fingerprint))
        context.acknowledged.formIntersection(fingerprints)
        context.alerted.formIntersection(fingerprints)
        context.autoJoined.formIntersection(fingerprints)
    }

    public func setError(_ message: String) {
        Log.error("Application error: \(message)")
        transition(to: .error)
    }

    public func clearError() {
        if state == .error { transition(to: .idle) }
    }

    public func updateSyncTime(_ date: Date) { context.lastSyncTime = date }

    private func isCurrent(_ fingerprint: String) -> Bool { context.currentMeeting?.fingerprint == fingerprint }

    private func transition(to newState: AppState) {
        guard state != newState else { return }
        let old = state
        state = newState
        Log.info("State transition: \(old.rawValue) -> \(newState.rawValue)")
        onTransition?(old, newState)
    }
}
