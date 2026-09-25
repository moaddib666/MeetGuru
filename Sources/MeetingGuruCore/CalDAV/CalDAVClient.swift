import Foundation

public enum CalDAVError: Error, Equatable, CustomStringConvertible {
    case authentication(String)
    case connection(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .authentication(let message): "Authentication failed: \(message)"
        case .connection(let message): "Connection failed: \(message)"
        case .badResponse(let message): message
        }
    }
}

public protocol CalendarProvider: Sendable {
    func events(in range: DateInterval) async throws -> [MeetingEvent]
    func invites(in range: DateInterval) async throws -> [MeetingInvite]
    func respond(to invite: MeetingInvite, with response: InviteResponse) async throws
    func reset() async
}

extension CalendarProvider {
    public func invites(in range: DateInterval) async throws -> [MeetingInvite] { [] }

    public func respond(to invite: MeetingInvite, with response: InviteResponse) async throws {
        throw CalDAVError.badResponse("This calendar can't send replies")
    }
}

public struct DiscoveredCalendar: Equatable, Sendable {
    public var url: URL
    public var name: String
}

/// CalDAV client: discovers the principal's calendars, then runs time-range REPORTs.
public actor CalDAVClient: CalendarProvider {
    public static let lookBehind: TimeInterval = 86_400
    public static let lookAhead: TimeInterval = 2 * 86_400
    /// How far ahead new invitations are looked for.
    public static let inviteLookAhead: TimeInterval = 60 * 86_400

    private let config: CalDAVConfig
    private let transport: HTTPTransport
    private let parser: EventParser
    private var calendar: DiscoveredCalendar?
    private var serverExpands = true
    private var ownAddresses: Set<String>

    public init(config: CalDAVConfig, transport: HTTPTransport? = nil) {
        self.config = config
        let usesPassword = (config.token ?? "").isEmpty
        self.transport =
            transport
            ?? URLSessionTransport(
                verifySSL: config.verifySSL,
                username: usesPassword ? config.username : nil,
                password: usesPassword ? config.password : nil)
        parser = EventParser(ownAddress: config.username)
        ownAddresses = config.username.isEmpty ? [] : [config.username.lowercased()]
    }

    public static func defaultRange(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-lookBehind), end: now.addingTimeInterval(lookAhead))
    }

    public static func inviteRange(now: Date) -> DateInterval {
        DateInterval(start: now, end: now.addingTimeInterval(inviteLookAhead))
    }

    /// The login plus every address the server lists in `calendar-user-address-set`.
    public var addresses: Set<String> { ownAddresses }

    public var isConnected: Bool { calendar != nil }

    public func reset() { calendar = nil }

    @discardableResult
    public func connect() async throws -> DiscoveredCalendar {
        guard let base = URL(string: config.url) else { throw CalDAVError.connection("Invalid server URL") }
        let discovered = try await discover(base: base)
        calendar = discovered
        Log.info("Connected to CalDAV server, using calendar: \(discovered.name)")
        return discovered
    }

    public func events(in range: DateInterval) async throws -> [MeetingEvent] {
        do {
            let target = try await calendarOrConnect()
            let events = try await report(target.url, range: range)
            Log.info("Synced \(events.count) events from CalDAV")
            return events.sorted { $0.start < $1.start }
        } catch {
            calendar = nil
            throw error
        }
    }

    /// Events in `range` still waiting for the user's answer. Fetched unexpanded, so a reply
    /// can be written back to the exact resource the server holds.
    public func invites(in range: DateInterval) async throws -> [MeetingInvite] {
        do {
            let target = try await calendarOrConnect()
            var request = makeRequest(target.url, method: "REPORT", depth: "1")
            request.httpBody = DAV.calendarQuery(start: range.start, end: range.end, expand: false)
            let detector = InviteDetector(addresses: ownAddresses)
            let invites = DAV.responses(in: try XMLNode.parse(try await perform(request))).compactMap { response -> MeetingInvite? in
                guard let data = response.property("calendar-data", DAV.caldav)?.text, !data.isEmpty else { return nil }
                return detector.invite(
                    resource: resolve(response.href, against: target.url),
                    etag: response.property("getetag")?.trimmedText,
                    calendarData: data, now: range.start, until: range.end)
            }
            Log.info("Found \(invites.count) pending invitations")
            return invites.sorted { $0.meeting.start < $1.meeting.start }
        } catch {
            calendar = nil
            throw error
        }
    }

    /// Writes the answer into the user's copy of the event; the server's implicit scheduling
    /// (RFC 6638) then sends the reply to the organiser. A changed resource is re-read once.
    public func respond(to invite: MeetingInvite, with response: InviteResponse) async throws {
        _ = try await calendarOrConnect()
        var calendarData = invite.calendarData
        var etag = invite.etag
        for attempt in 0..<2 {
            guard let body = ICalendar.answering(response, as: ownAddresses, in: calendarData) else {
                throw CalDAVError.badResponse("You are not an attendee of this meeting")
            }
            var request = makeRequest(invite.resource, method: "PUT", depth: nil)
            request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
            if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-Match") }
            request.httpBody = Data(body.utf8)
            let (_, reply) = try await exchange(request)
            if reply.statusCode == 412, attempt == 0 {
                Log.info("Invite changed on the server, re-reading it before replying")
                let fresh = makeRequest(invite.resource, method: "GET", depth: nil)
                let (data, got) = try await exchange(fresh)
                try check(got, for: fresh)
                calendarData = String(decoding: data, as: UTF8.self)
                etag = got.value(forHTTPHeaderField: "ETag")
                continue
            }
            try check(reply, for: request)
            Log.info("Replied \(response.rawValue) to '\(invite.meeting.title)'")
            return
        }
    }

    /// The Settings "Test connection" check.
    public func testConnection() async -> (ok: Bool, message: String) {
        do {
            let found = try await connect()
            return (true, "Connected to “\(found.name)”")
        } catch let error as CalDAVError {
            return (false, error.description)
        } catch {
            return (false, "Connection failed: \(error.localizedDescription)")
        }
    }

    private func calendarOrConnect() async throws -> DiscoveredCalendar {
        if let calendar { return calendar }
        return try await connect()
    }

    private func discover(base: URL) async throws -> DiscoveredCalendar {
        let root: DAV.Response?
        do {
            root = try await propfind(
                base, depth: 0,
                props: [
                    ("current-user-principal", DAV.dav), ("calendar-home-set", DAV.caldav),
                    ("resourcetype", DAV.dav), ("displayname", DAV.dav), ("calendar-user-address-set", DAV.caldav),
                ]
            ).first
        } catch CalDAVError.badResponse(let message) {
            Log.info("PROPFIND on \(base.path) failed (\(message)), trying /.well-known/caldav")
            root = nil
        }

        learnAddresses(from: root)
        let rootIsCalendar = root?.property("resourcetype")?.child("calendar", DAV.caldav) != nil
        let rootName = root?.property("displayname")?.trimmedText ?? ""
        if rootIsCalendar, config.calendarName == "default" || config.calendarName == rootName {
            return DiscoveredCalendar(url: base, name: rootName.isEmpty ? base.lastPathComponent : rootName)
        }

        var principal = root?.property("current-user-principal")?.child("href").map { resolve($0.trimmedText, against: base) }
        if principal == nil, let wellKnown = URL(string: "/.well-known/caldav", relativeTo: base)?.absoluteURL {
            let fallback = try? await propfind(wellKnown, depth: 0, props: [("current-user-principal", DAV.dav)]).first
            principal = fallback?.property("current-user-principal")?.child("href").map { resolve($0.trimmedText, against: wellKnown) }
        }
        let principalURL = principal ?? base

        var home = root?.property("calendar-home-set", DAV.caldav)?.child("href").map { resolve($0.trimmedText, against: base) }
        if home == nil || principalURL != base {
            let principalProps = try await propfind(
                principalURL, depth: 0, props: [("calendar-home-set", DAV.caldav), ("calendar-user-address-set", DAV.caldav)]
            ).first
            learnAddresses(from: principalProps)
            home =
                principalProps?.property("calendar-home-set", DAV.caldav)?.child("href").map { resolve($0.trimmedText, against: principalURL) }
                ?? home
        }
        let homeURL = home ?? principalURL

        let listing = try await propfind(
            homeURL, depth: 1,
            props: [
                ("resourcetype", DAV.dav), ("displayname", DAV.dav), ("supported-calendar-component-set", DAV.caldav),
            ])
        let calendars: [DiscoveredCalendar] = listing.compactMap { response in
            guard response.property("resourcetype")?.child("calendar", DAV.caldav) != nil else { return nil }
            let components = response.property("supported-calendar-component-set", DAV.caldav)?.all("comp", DAV.caldav) ?? []
            if !components.isEmpty, !components.contains(where: { $0.attributes["name"]?.uppercased() == "VEVENT" }) {
                return nil
            }
            let url = resolve(response.href, against: homeURL)
            let name = response.property("displayname")?.trimmedText ?? ""
            return DiscoveredCalendar(url: url, name: name.isEmpty ? url.lastPathComponent : name)
        }

        if rootIsCalendar, calendars.isEmpty {
            return DiscoveredCalendar(url: base, name: rootName.isEmpty ? base.lastPathComponent : rootName)
        }
        guard let first = calendars.first else { throw CalDAVError.connection("No calendars found") }
        if config.calendarName == "default" { return first }
        if let match = calendars.first(where: { $0.name == config.calendarName }) { return match }
        Log.error("Calendar '\(config.calendarName)' not found, using '\(first.name)'")
        return first
    }

    private func learnAddresses(from response: DAV.Response?) {
        let found =
            response?.property("calendar-user-address-set", DAV.caldav)?.all("href").map(\.trimmedText)
            .filter { $0.lowercased().hasPrefix("mailto:") }
            .map { EventParser.stripMailto($0).lowercased() } ?? []
        ownAddresses.formUnion(found)
    }

    private func report(_ url: URL, range: DateInterval) async throws -> [MeetingEvent] {
        if serverExpands {
            do {
                return try await runReport(url, range: range, expand: true)
            } catch CalDAVError.badResponse(let message) where message.hasPrefix("HTTP 4") || message.hasPrefix("HTTP 5") {
                Log.info("Server rejected expanded REPORT (\(message)); expanding recurrences locally")
                serverExpands = false
            }
        }
        return try await runReport(url, range: range, expand: false)
    }

    private func runReport(_ url: URL, range: DateInterval, expand: Bool) async throws -> [MeetingEvent] {
        var request = makeRequest(url, method: "REPORT", depth: "1")
        request.httpBody = DAV.calendarQuery(start: range.start, end: range.end, expand: expand)
        let root = try XMLNode.parse(try await perform(request))
        return DAV.responses(in: root).flatMap { response -> [MeetingEvent] in
            guard let data = response.property("calendar-data", DAV.caldav)?.text, !data.isEmpty else { return [] }
            return parser.meetings(from: data, range: range)
        }
    }

    private func propfind(_ url: URL, depth: Int, props: [(String, String)]) async throws -> [DAV.Response] {
        var request = makeRequest(url, method: "PROPFIND", depth: String(depth))
        request.httpBody = DAV.propfind(props)
        return DAV.responses(in: try XMLNode.parse(try await perform(request)))
    }

    private func makeRequest(_ url: URL, method: String, depth: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(config.timeout))
        request.httpMethod = method
        if let depth { request.setValue(depth, forHTTPHeaderField: "Depth") }
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let password = config.password {
            let basic = Data("\(config.username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await exchange(request)
        try check(response, for: request)
        return data
    }

    private func exchange(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as CalDAVError {
            throw error
        } catch {
            throw CalDAVError.connection(error.localizedDescription)
        }
    }

    private func check(_ response: HTTPURLResponse, for request: URLRequest) throws {
        switch response.statusCode {
        case 200...299: return
        case 401, 403: throw CalDAVError.authentication("server answered \(response.statusCode)")
        default: throw CalDAVError.badResponse("HTTP \(response.statusCode) for \(request.httpMethod ?? "") \(request.url?.path ?? "")")
        }
    }

    private nonisolated func resolve(_ href: String, against base: URL) -> URL {
        URL(string: href, relativeTo: base)?.absoluteURL ?? base
    }
}
