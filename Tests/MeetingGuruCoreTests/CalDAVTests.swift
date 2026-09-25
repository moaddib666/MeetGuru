import Foundation
import Testing
import os

@testable import MeetingGuruCore

/// Scripted CalDAV server: answers by method + path and records every request.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, String)
    private let lock = OSAllocatedUnfairLock(initialState: [URLRequest]())
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { $0.append(request) }
        let (status, body) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

enum Server {
    static func multistatus(_ responses: String) -> String {
        #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">\#(responses)</d:multistatus>"#
    }

    static func response(_ href: String, _ props: String) -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(props)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    static func calendar(_ href: String, _ name: String, components: [String] = ["VEVENT"]) -> String {
        let comps = components.map { "<cal:comp name=\"\($0)\"/>" }.joined()
        return response(
            href,
            "<d:resourcetype><d:collection/><cal:calendar/></d:resourcetype><d:displayname>\(name)</d:displayname><cal:supported-calendar-component-set>\(comps)</cal:supported-calendar-component-set>"
        )
    }

    static let event = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        UID:evt-1\r
        SUMMARY:Standup &amp; sync\r
        DTSTART:20260923T100000Z\r
        DTEND:20260923T101500Z\r
        LOCATION:https://meet.google.com/abc-defg-hij\r
        END:VEVENT\r
        END:VCALENDAR\r
        """

    /// A standard principal → home → calendars layout.
    static func standard(reportStatus: Int = 207, report: String? = nil) -> FakeTransport.Handler {
        { request in
            let path = request.url!.path
            switch (request.httpMethod!, path) {
            case ("PROPFIND", "/"):
                return (207, multistatus(response("/", "<d:current-user-principal><d:href>/principals/me/</d:href></d:current-user-principal>")))
            case ("PROPFIND", "/principals/me"), ("PROPFIND", "/principals/me/"):
                return (
                    207, multistatus(response("/principals/me/", "<cal:calendar-home-set><d:href>/calendars/me/</d:href></cal:calendar-home-set>"))
                )
            case ("PROPFIND", "/calendars/me"), ("PROPFIND", "/calendars/me/"):
                return (
                    207,
                    multistatus(
                        response("/calendars/me/", "<d:resourcetype><d:collection/></d:resourcetype>")
                            + calendar("/calendars/me/tasks/", "Tasks", components: ["VTODO"])
                            + calendar("/calendars/me/work/", "Work")
                            + calendar("/calendars/me/home/", "Home"))
                )
            case ("REPORT", _):
                let body =
                    report ?? multistatus(response("\(path)/e1.ics", "<d:getetag>\"1\"</d:getetag><cal:calendar-data>\(event)</cal:calendar-data>"))
                return (reportStatus, body)
            default:
                return (404, "")
            }
        }
    }
}

@Suite struct CalDAVClientTests {
    let range = DateInterval(start: utc("2026-09-22T00:00:00Z"), end: utc("2026-09-25T00:00:00Z"))

    func config(calendar: String = "default", token: String? = nil) -> CalDAVConfig {
        CalDAVConfig(
            url: "https://dav.example.com/", username: "me@example.com", password: token == nil ? "pw" : nil, token: token, calendarName: calendar)
    }

    @Test func discoversTheFirstEventCalendarByDefault() async throws {
        let transport = FakeTransport(Server.standard())
        let client = CalDAVClient(config: config(), transport: transport)
        let found = try await client.connect()
        #expect(found.name == "Work")
        #expect(found.url.absoluteString == "https://dav.example.com/calendars/me/work/")
        #expect(transport.requests.map(\.httpMethod) == ["PROPFIND", "PROPFIND", "PROPFIND"])
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Depth") == "1")
    }

    @Test func picksTheNamedCalendar() async throws {
        let client = CalDAVClient(config: config(calendar: "Home"), transport: FakeTransport(Server.standard()))
        #expect(try await client.connect().name == "Home")
    }

    @Test func unknownCalendarNameFallsBackToTheFirst() async throws {
        let client = CalDAVClient(config: config(calendar: "Nope"), transport: FakeTransport(Server.standard()))
        #expect(try await client.connect().name == "Work")
    }

    @Test func fetchesAndParsesEvents() async throws {
        let transport = FakeTransport(Server.standard())
        let client = CalDAVClient(config: config(), transport: transport)
        let events = try await client.events(in: range)
        #expect(events.count == 1)
        #expect(events.first?.title == "Standup & sync")
        #expect(events.first?.meetingURL == "https://meet.google.com/abc-defg-hij")
        let report = try #require(transport.requests.last)
        let body = String(decoding: report.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#"<C:time-range start="20260922T000000Z" end="20260925T000000Z"/>"#))
        #expect(body.contains("<C:expand"))
    }

    @Test func sendsBasicAuthOrBearer() async throws {
        let basic = FakeTransport(Server.standard())
        _ = try await CalDAVClient(config: config(), transport: basic).connect()
        let expected = "Basic " + Data("me@example.com:pw".utf8).base64EncodedString()
        #expect(basic.requests.first?.value(forHTTPHeaderField: "Authorization") == expected)

        let bearer = FakeTransport(Server.standard())
        _ = try await CalDAVClient(config: config(token: "abc"), transport: bearer).connect()
        #expect(bearer.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
    }

    @Test func unauthorisedIsAnAuthenticationError() async {
        let client = CalDAVClient(config: config(), transport: FakeTransport { _ in (401, "") })
        await #expect(throws: CalDAVError.authentication("server answered 401")) {
            try await client.connect()
        }
        let result = await client.testConnection()
        #expect(!result.ok)
        #expect(result.message.hasPrefix("Authentication failed"))
    }

    @Test func noCalendarsIsAConnectionError() async {
        let client = CalDAVClient(
            config: config(),
            transport: FakeTransport { request in
                (207, Server.multistatus(Server.response(request.url!.path, "<d:resourcetype><d:collection/></d:resourcetype>")))
            })
        await #expect(throws: CalDAVError.connection("No calendars found")) { try await client.connect() }
    }

    @Test func calendarURLIsUsedDirectly() async throws {
        let transport = FakeTransport { request in
            (207, Server.multistatus(Server.calendar(request.url!.path, "Direct")))
        }
        let client = CalDAVClient(
            config: CalDAVConfig(url: "https://dav.example.com/caldav/Y2Fs/", username: "me", password: "pw"), transport: transport)
        let found = try await client.connect()
        #expect(found.name == "Direct")
        #expect(transport.requests.count == 1)
    }

    @Test func serverWithoutExpandFallsBackToLocalExpansion() async throws {
        let recurring = """
            BEGIN:VCALENDAR\r
            BEGIN:VEVENT\r
            UID:daily\r
            SUMMARY:Daily\r
            DTSTART:20260901T090000Z\r
            DTEND:20260901T091500Z\r
            RRULE:FREQ=DAILY\r
            END:VEVENT\r
            END:VCALENDAR\r
            """
        let transport = FakeTransport { request in
            if request.httpMethod == "REPORT" {
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                if body.contains("expand") { return (501, "") }
                return (207, Server.multistatus(Server.response("/cal/d.ics", "<cal:calendar-data>\(recurring)</cal:calendar-data>")))
            }
            return try Server.standard()(request)
        }
        let client = CalDAVClient(config: config(), transport: transport)
        let events = try await client.events(in: range)
        #expect(events.map(\.start) == [utc("2026-09-22T09:00:00Z"), utc("2026-09-23T09:00:00Z"), utc("2026-09-24T09:00:00Z")])
        _ = try await client.events(in: range)
        let reports = transport.requests.filter { $0.httpMethod == "REPORT" }
        #expect(reports.count == 3, "expand is only attempted once")
    }

    @Test func failedSearchDisconnects() async throws {
        let client = CalDAVClient(config: config(), transport: FakeTransport(Server.standard(reportStatus: 500, report: "")))
        _ = try await client.connect()
        #expect(await client.isConnected)
        await #expect(throws: CalDAVError.self) { try await client.events(in: range) }
        #expect(await !client.isConnected)
    }

    @Test func rejectedRootFallsBackToWellKnown() async throws {
        let transport = FakeTransport { request in
            switch request.url!.path {
            case "/": return (405, "")
            case "/.well-known/caldav":
                return (
                    207,
                    Server.multistatus(Server.response("/", "<d:current-user-principal><d:href>/principals/me/</d:href></d:current-user-principal>"))
                )
            default: return try Server.standard()(request)
            }
        }
        let client = CalDAVClient(config: config(), transport: transport)
        #expect(try await client.connect().name == "Work")
    }

    @Test func transportErrorsBecomeConnectionErrors() async {
        struct Down: Error {}
        let client = CalDAVClient(config: config(), transport: FakeTransport { _ in throw Down() })
        await #expect(throws: CalDAVError.self) { try await client.connect() }
    }
}
