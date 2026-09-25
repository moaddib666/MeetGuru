import Foundation

@testable import MeetingGuruCore

let referenceNow = Date(timeIntervalSince1970: 1_790_164_800)

func meeting(
    _ uid: String, startIn minutes: Double, duration: Double = 30, now: Date = referenceNow,
    location: String? = nil, details: String? = nil, url: String? = nil,
    allDay: Bool = false, conferenceURLs: [String] = []
) -> MeetingEvent {
    let start = now.addingTimeInterval(minutes * 60)
    return MeetingEvent(
        uid: uid, title: uid, start: start, end: start.addingTimeInterval(duration * 60),
        location: location, details: details, url: url, allDay: allDay, conferenceURLs: conferenceURLs)
}

func ical(_ body: String) -> String {
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:1\r\nSUMMARY:Sync\r\n\(body)END:VEVENT\r\nEND:VCALENDAR\r\n"
}

func utc(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)!
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mg-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
