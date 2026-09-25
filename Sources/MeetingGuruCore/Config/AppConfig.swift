import Foundation

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case io(String)

    public var description: String {
        switch self {
        case .invalid(let message): message
        case .io(let message): message
        }
    }
}

/// Wire-compatible with the Python `CalDAVConfig` pydantic model.
public struct CalDAVConfig: Codable, Equatable, Sendable {
    public static let placeholderURL = "https://caldav.example.com/"
    public static let placeholderUsername = "your_username"

    public var url: String
    public var username: String
    public var password: String?
    public var token: String?
    public var calendarName: String = "default"
    public var timeout: Int = 10
    public var verifySSL: Bool = true
    public var useCache: Bool = true
    public var syncInterval: Int = 60
    public var syncOnStart: Bool = true

    public init(
        url: String,
        username: String,
        password: String? = nil,
        token: String? = nil,
        calendarName: String = "default",
        timeout: Int = 10,
        verifySSL: Bool = true,
        useCache: Bool = true,
        syncInterval: Int = 60,
        syncOnStart: Bool = true
    ) {
        self.url = url
        self.username = username
        self.password = password
        self.token = token
        self.calendarName = calendarName
        self.timeout = timeout
        self.verifySSL = verifySSL
        self.useCache = useCache
        self.syncInterval = syncInterval
        self.syncOnStart = syncOnStart
    }

    enum CodingKeys: String, CodingKey {
        case url, username, password, token
        case calendarName = "calendar_name"
        case timeout
        case verifySSL = "verify_ssl"
        case useCache = "use_cache"
        case syncInterval = "sync_interval"
        case syncOnStart = "sync_on_start"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        calendarName = try c.decodeIfPresent(String.self, forKey: .calendarName) ?? "default"
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 10
        verifySSL = try c.decodeIfPresent(Bool.self, forKey: .verifySSL) ?? true
        useCache = try c.decodeIfPresent(Bool.self, forKey: .useCache) ?? true
        syncInterval = try c.decodeIfPresent(Int.self, forKey: .syncInterval) ?? 60
        syncOnStart = try c.decodeIfPresent(Bool.self, forKey: .syncOnStart) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(username, forKey: .username)
        try c.encode(password, forKey: .password)
        try c.encode(token, forKey: .token)
        try c.encode(calendarName, forKey: .calendarName)
        try c.encode(timeout, forKey: .timeout)
        try c.encode(verifySSL, forKey: .verifySSL)
        try c.encode(useCache, forKey: .useCache)
        try c.encode(syncInterval, forKey: .syncInterval)
        try c.encode(syncOnStart, forKey: .syncOnStart)
    }

    public var isPlaceholder: Bool {
        url == Self.placeholderURL || username == Self.placeholderUsername
    }

    /// Applies the pydantic rules: http(s) URL with a trailing slash, ranges, and credentials.
    public func validated() throws -> CalDAVConfig {
        var copy = self
        copy.url = url.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: copy.url),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty
        else { throw ConfigError.invalid("Server URL must be a valid http(s) address") }
        if !copy.url.hasSuffix("/") { copy.url += "/" }
        guard (1...300).contains(timeout) else { throw ConfigError.invalid("Timeout must be 1–300 seconds") }
        guard (5...3600).contains(syncInterval) else {
            throw ConfigError.invalid("Sync interval must be 5–3600 seconds")
        }
        if !copy.isPlaceholder, (password ?? "").isEmpty, (token ?? "").isEmpty {
            throw ConfigError.invalid("Either password or token must be provided")
        }
        return copy
    }
}

/// Wire-compatible with the Python `AppConfig` pydantic model.
public struct AppConfig: Codable, Equatable, Sendable {
    public var caldav: CalDAVConfig
    public var alertAdvanceMinutes: Int = 1
    public var autoJoinDelaySeconds: Int = 5
    public var trayUpdateInterval: Int = 10
    public var showMissedMeetings: Bool = true
    public var notificationSound: Bool = true
    public var soundVolume: Double = 0.7
    public var debugMode: Bool = false
    public var trayColorDefault: String = "#FFFFFF"
    public var trayColorAlert: String = "#FF4500"
    public var trayColorWarning: String = "#FFD700"
    public var trayColorOk: String = "#00FF00"

    public init(caldav: CalDAVConfig) {
        self.caldav = caldav
    }

    public static var placeholder: AppConfig {
        AppConfig(
            caldav: CalDAVConfig(
                url: CalDAVConfig.placeholderURL,
                username: CalDAVConfig.placeholderUsername,
                password: "your_password"))
    }

    enum CodingKeys: String, CodingKey {
        case caldav
        case alertAdvanceMinutes = "alert_advance_minutes"
        case autoJoinDelaySeconds = "auto_join_delay_seconds"
        case trayUpdateInterval = "tray_update_interval"
        case showMissedMeetings = "show_missed_meetings"
        case notificationSound = "notification_sound"
        case soundVolume = "sound_volume"
        case debugMode = "debug_mode"
        case trayColorDefault = "tray_color_default"
        case trayColorAlert = "tray_color_alert"
        case trayColorWarning = "tray_color_warning"
        case trayColorOk = "tray_color_ok"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caldav = try c.decode(CalDAVConfig.self, forKey: .caldav)
        alertAdvanceMinutes = try c.decodeIfPresent(Int.self, forKey: .alertAdvanceMinutes) ?? 1
        autoJoinDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .autoJoinDelaySeconds) ?? 5
        trayUpdateInterval = try c.decodeIfPresent(Int.self, forKey: .trayUpdateInterval) ?? 10
        showMissedMeetings = try c.decodeIfPresent(Bool.self, forKey: .showMissedMeetings) ?? true
        notificationSound = try c.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? true
        soundVolume = try c.decodeIfPresent(Double.self, forKey: .soundVolume) ?? 0.7
        debugMode = try c.decodeIfPresent(Bool.self, forKey: .debugMode) ?? false
        trayColorDefault = try c.decodeIfPresent(String.self, forKey: .trayColorDefault) ?? "#FFFFFF"
        trayColorAlert = try c.decodeIfPresent(String.self, forKey: .trayColorAlert) ?? "#FF4500"
        trayColorWarning = try c.decodeIfPresent(String.self, forKey: .trayColorWarning) ?? "#FFD700"
        trayColorOk = try c.decodeIfPresent(String.self, forKey: .trayColorOk) ?? "#00FF00"
    }

    public func validated() throws -> AppConfig {
        var copy = self
        copy.caldav = try caldav.validated()
        guard (1...60).contains(alertAdvanceMinutes) else {
            throw ConfigError.invalid("Alert advance must be 1–60 minutes")
        }
        guard (0...60).contains(autoJoinDelaySeconds) else {
            throw ConfigError.invalid("Auto-join delay must be 0–60 seconds")
        }
        guard (1...300).contains(trayUpdateInterval) else {
            throw ConfigError.invalid("Tray update interval must be 1–300 seconds")
        }
        guard (0.0...1.0).contains(soundVolume) else {
            throw ConfigError.invalid("Sound volume must be between 0 and 1")
        }
        return copy
    }

    /// JSON as `--show-config` prints it, with secrets masked.
    public func redactedJSON() throws -> String {
        var copy = self
        if copy.caldav.password?.isEmpty == false { copy.caldav.password = "***hidden***" }
        if copy.caldav.token?.isEmpty == false { copy.caldav.token = "***hidden***" }
        return String(decoding: try ConfigStore.encoder.encode(copy), as: UTF8.self)
    }
}
