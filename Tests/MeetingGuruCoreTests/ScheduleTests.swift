import Foundation
import Testing

@testable import MeetingGuruCore

@Suite struct ScheduleTests {
    let config = AppConfig.placeholder

    @Test func trayColoursFollowTheDay() {
        #expect(MeetingSchedule(events: [], now: referenceNow).trayStatus(dndActive: false).colorHex(for: config) == "#FFFFFF")
        #expect(MeetingSchedule(events: [meeting("live", startIn: -5)], now: referenceNow).trayStatus(dndActive: false) == .alert)
        #expect(MeetingSchedule(events: [meeting("soon", startIn: 10)], now: referenceNow).trayStatus(dndActive: false) == .warning)
        #expect(MeetingSchedule(events: [meeting("later", startIn: 60)], now: referenceNow).trayStatus(dndActive: false) == .ok)
        #expect(
            MeetingSchedule(events: [meeting("live", startIn: -5)], now: referenceNow).trayStatus(dndActive: true).colorHex(for: config) == "#808080")
    }

    @Test func currentBeatsUpcoming() {
        let schedule = MeetingSchedule(events: [meeting("later", startIn: 5), meeting("live", startIn: -5)], now: referenceNow)
        #expect(schedule.trayStatus(dndActive: false) == .alert)
        #expect(schedule.featured?.uid == "live")
    }

    @Test func allDayEventsAreLeftOut() {
        let schedule = MeetingSchedule(events: [meeting("holiday", startIn: -60, duration: 1440, allDay: true)], now: referenceNow)
        #expect(schedule.current.isEmpty)
        #expect(schedule.trayStatus(dndActive: false) == .idle)
    }

    @Test func nearestAndNextAreSorted() {
        let schedule = MeetingSchedule(
            events: [meeting("c", startIn: 300), meeting("a", startIn: 20), meeting("b", startIn: 90), meeting("done", startIn: -90)],
            now: referenceNow)
        #expect(schedule.nearest?.uid == "a")
        #expect(schedule.next?.uid == "b")
    }

    @Test func tooltipsMatchThePythonTray() {
        #expect(MeetingSchedule(events: [], now: referenceNow).tooltip(syncError: nil, dnd: DNDState()) == "MeetingGuru - No upcoming meetings")
        #expect(
            MeetingSchedule(events: [meeting("Standup", startIn: 12)], now: referenceNow).tooltip(syncError: nil, dnd: DNDState())
                == "MeetingGuru - Next: Standup (in 12 min)")
        #expect(
            MeetingSchedule(events: [meeting("Review", startIn: 150)], now: referenceNow).tooltip(syncError: nil, dnd: DNDState())
                == "MeetingGuru - Next: Review (in 2h 30m)")
        #expect(
            MeetingSchedule(events: [meeting("Live", startIn: -1)], now: referenceNow).tooltip(syncError: "boom", dnd: DNDState())
                == "MeetingGuru - Current: Live\nSync error: boom")

        var dnd = DNDState()
        dnd.start(.oneHour, at: referenceNow.addingTimeInterval(-600))
        #expect(
            MeetingSchedule(events: [], now: referenceNow).tooltip(syncError: nil, dnd: dnd)
                == "MeetingGuru - No upcoming meetings\nDND: 50m remaining")
    }

    @Test func formatting() {
        #expect(Formatting.shortDuration(30) == "< 1m")
        #expect(Formatting.shortDuration(600) == "10m")
        #expect(Formatting.shortDuration(3600) == "1h")
        #expect(Formatting.shortDuration(3900) == "1h 5m")
        #expect(Formatting.countdown(42) == "0:42")
        #expect(Formatting.countdown(41.2) == "0:42")
        #expect(Formatting.countdown(725) == "12:05")
        #expect(Formatting.countdown(8040) == "2h 14m")
        #expect(Formatting.tooltipDuration(2 * 86_400 + 5) == "2 days")
    }
}

@Suite struct DoNotDisturbTests {
    @Test func timedPauseExpires() {
        var dnd = DNDState()
        dnd.start(.thirtyMinutes, at: referenceNow)
        #expect(dnd.isActive(at: referenceNow.addingTimeInterval(29 * 60)))
        #expect(dnd.remaining(at: referenceNow.addingTimeInterval(20 * 60)) == 600)
        #expect(!dnd.isActive(at: referenceNow.addingTimeInterval(30 * 60)))
    }

    @Test func untilResumeNeverExpires() {
        var dnd = DNDState()
        dnd.start(.untilResume, at: referenceNow)
        #expect(dnd.isActive(at: referenceNow.addingTimeInterval(86_400 * 30)))
        #expect(dnd.remaining(at: referenceNow) == nil)
        #expect(dnd.elapsed(at: referenceNow.addingTimeInterval(90)) == 90)
        dnd.stop()
        #expect(!dnd.isActive(at: referenceNow))
    }

    @Test(arguments: zip(DNDDuration.allCases, [30, 60, 180, 300, 720, nil] as [Int?]))
    func durationsMatchThePythonTable(duration: DNDDuration, minutes: Int?) {
        #expect(duration.minutes == minutes)
    }
}
