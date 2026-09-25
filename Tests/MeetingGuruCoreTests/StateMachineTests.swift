import Foundation
import Testing

@testable import MeetingGuruCore

/// Ports of the Python `TestMeetingSelection` regression suite.
@Suite struct StateMachineTests {
    let now = referenceNow

    @Test func overlappingMeetingTakesAlertAtItsOwnStart() {
        let sm = StateMachine()
        let first = meeting("first", startIn: -20, duration: 60)
        let second = meeting("second", startIn: 0.5)
        #expect(sm.selectMeeting(from: [first, second], alertAdvanceMinutes: 1, now: now) == second)
    }

    @Test func autoJoinedOngoingMeetingDoesNotBlockNext() {
        let sm = StateMachine()
        let first = meeting("first", startIn: -20, duration: 60)
        let second = meeting("second", startIn: 0.5)
        sm.setCurrentMeeting(first)
        sm.showAlert(at: now)
        sm.markAutoJoined(first.fingerprint)

        let current = sm.selectMeeting(from: [first, second], alertAdvanceMinutes: 1, now: now)
        #expect(current == second)
        sm.setCurrentMeeting(current)
        #expect(sm.shouldShowAlert)
    }

    @Test func displacedAutoJoinedMeetingDoesNotComeBack() {
        let sm = StateMachine()
        let first = meeting("first", startIn: -20, duration: 60)
        let second = meeting("second", startIn: 0.5)
        sm.markAutoJoined(first.fingerprint)
        sm.setCurrentMeeting(second)
        sm.participate(second.fingerprint)
        #expect(sm.selectMeeting(from: [first, second], alertAdvanceMinutes: 1, now: now) == nil)
    }

    @Test func sameStartMeetingsAreAlertedOneAfterAnother() {
        let sm = StateMachine()
        let a = meeting("a", startIn: 0.5)
        var b = meeting("b", startIn: 0.5)
        b.start = a.start
        b.end = a.end

        let chosen = sm.selectMeeting(from: [a, b], alertAdvanceMinutes: 1, now: now)
        #expect(chosen == a, "ties keep the first meeting, like Python's max()")
        sm.setCurrentMeeting(chosen)
        sm.acknowledge(chosen!.fingerprint)

        let other = sm.selectMeeting(from: [a, b], alertAdvanceMinutes: 1, now: now)
        #expect(other == b)
    }

    @Test func meetingOutsideAlertWindowIsNotSelected() {
        #expect(StateMachine().selectMeeting(from: [meeting("later", startIn: 4)], alertAdvanceMinutes: 1, now: now) == nil)
    }

    @Test func finishedAndAllDayMeetingsAreIgnored() {
        let finished = meeting("done", startIn: -60)
        let allDay = meeting("holiday", startIn: -60, duration: 24 * 60, allDay: true)
        #expect(StateMachine().selectMeeting(from: [finished, allDay], alertAdvanceMinutes: 1, now: now) == nil)
    }

    @Test func errorStateDoesNotSuppressAlerts() {
        let sm = StateMachine()
        sm.initializeComplete()
        sm.setError("sync failed")
        sm.setCurrentMeeting(meeting("m", startIn: 0.5))
        #expect(sm.shouldShowAlert)
    }

    @Test func autoJoinHappensOncePerMeeting() {
        let sm = StateMachine()
        let m = meeting("m", startIn: 0.5)
        sm.setCurrentMeeting(m)
        sm.showAlert(at: now.addingTimeInterval(-10))
        #expect(sm.shouldAutoParticipate(delaySeconds: 5, now: now))
        sm.markAutoJoined(m.fingerprint)
        #expect(!sm.shouldAutoParticipate(delaySeconds: 5, now: now))
    }

    @Test func autoJoinWaitsForTheDelay() {
        let sm = StateMachine()
        sm.setCurrentMeeting(meeting("m", startIn: 0.5))
        sm.showAlert(at: now.addingTimeInterval(-3))
        #expect(!sm.shouldAutoParticipate(delaySeconds: 5, now: now))
    }

    @Test func soundOnlyOnFirstAlert() {
        let sm = StateMachine()
        let m = meeting("m", startIn: 0.5)
        sm.setCurrentMeeting(m)
        #expect(sm.showAlert(at: now))
        sm.setCurrentMeeting(nil)
        sm.setCurrentMeeting(m)
        #expect(!sm.showAlert(at: now))
        #expect(sm.state == .alertShowing)
    }

    @Test func removedMeetingsAreForgotten() {
        let sm = StateMachine()
        sm.acknowledge(meeting("m", startIn: 0.5).fingerprint)
        sm.forgetMissing([])
        #expect(sm.context.acknowledged.isEmpty)
    }

    @Test func acknowledgingCurrentMeetingReturnsToIdle() {
        let sm = StateMachine()
        sm.initializeComplete()
        let m = meeting("m", startIn: 0.5)
        sm.setCurrentMeeting(m)
        sm.showAlert(at: now)
        sm.acknowledge(m.fingerprint)
        #expect(sm.state == .idle)
        #expect(!sm.shouldShowAlert)
    }

    @Test func participatingMarksMeetingActive() {
        let sm = StateMachine()
        let m = meeting("m", startIn: 0.5)
        sm.setCurrentMeeting(m)
        sm.showAlert(at: now)
        sm.participate(m.fingerprint)
        #expect(sm.state == .meetingActive)
        #expect(sm.context.alertStatus == .autoJoined)
    }

    @Test func transitionsAreReported() {
        let sm = StateMachine()
        var seen: [AppState] = []
        sm.onTransition = { _, new in seen.append(new) }
        sm.initializeComplete()
        sm.setCurrentMeeting(meeting("m", startIn: 0.5))
        sm.showAlert(at: now)
        sm.setCurrentMeeting(nil)
        #expect(seen == [.idle, .alertPending, .alertShowing, .idle])
    }
}

@Suite struct MeetingEventTests {
    @Test func statusFollowsTheClock() {
        let m = meeting("m", startIn: 10)
        #expect(m.status(at: referenceNow) == .upcoming)
        #expect(m.status(at: referenceNow.addingTimeInterval(15 * 60)) == .current)
        #expect(m.status(at: referenceNow.addingTimeInterval(41 * 60)) == .completed)
    }

    @Test func fingerprintMatchesThePythonFormula() {
        var m = MeetingEvent(uid: "abc", title: "Standup", start: utc("2026-09-23T10:00:00Z"), end: utc("2026-09-23T10:30:00Z"), location: "Room 1")
        let first = m.fingerprint
        #expect(first.count == 16)
        #expect(first.allSatisfy { $0.isHexDigit })
        m.title = "Standup (moved)"
        #expect(m.fingerprint != first)
    }

    @Test func progressIsClamped() {
        let m = meeting("m", startIn: -15)
        #expect(m.progress(at: referenceNow) == 0.5)
        #expect(m.progress(at: referenceNow.addingTimeInterval(3600)) == 1)
    }
}
