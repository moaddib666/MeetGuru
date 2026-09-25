import Foundation

public protocol ConfigProviding: AnyObject {
    var configPath: String { get }
    var isWritable: Bool { get }
    func load() throws -> AppConfig
    func save(_ config: AppConfig) throws
    func reset() throws -> AppConfig
}

/// JSON config shared with the Python app (`appdirs.user_config_dir("MeetingGuru", "moaddib")`).
public final class ConfigStore: ConfigProviding {
    public static let maxBackups = 5

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    public let fileURL: URL
    public var directory: URL { fileURL.deletingLastPathComponent() }
    public var configPath: String { fileURL.path }
    public var isWritable: Bool { true }

    private let fileManager: FileManager
    private let now: () -> Date

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingGuru", isDirectory: true)
    }

    public convenience init(directory: URL = ConfigStore.defaultDirectory, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init)
    {
        self.init(fileURL: directory.appendingPathComponent("config.json"), fileManager: fileManager, now: now)
    }

    public init(fileURL: URL, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.now = now
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Python's `Path.with_suffix(".backup_<stamp>")`: "config.json" -> "config.backup_<stamp>".
    private var backupPrefix: String { fileURL.deletingPathExtension().lastPathComponent + ".backup_" }

    public var exists: Bool { fileManager.fileExists(atPath: fileURL.path) }

    public func load() throws -> AppConfig {
        guard exists else {
            Log.info("Configuration file not found, creating default configuration")
            return createDefault()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ConfigError.io("Failed to load configuration: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data).validated()
        } catch {
            Log.error("Invalid configuration file: \(error)")
            backup()
            return createDefault()
        }
    }

    public func save(_ config: AppConfig) throws {
        let valid = try config.validated()
        if exists { backup() }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(valid).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw ConfigError.io("Failed to save configuration: \(error.localizedDescription)")
        }
    }

    public func reset() throws -> AppConfig {
        let config = AppConfig.placeholder
        try save(config)
        return config
    }

    public func backupFiles() -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(backupPrefix) }.map { directory.appendingPathComponent($0) }
    }

    private func createDefault() -> AppConfig {
        let config = AppConfig.placeholder
        do {
            try save(config)
        } catch {
            Log.error("Could not save default configuration: \(error)")
        }
        return config
    }

    private func backup() {
        guard exists else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let target = directory.appendingPathComponent("\(backupPrefix)\(formatter.string(from: now()))")
        do {
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: fileURL, to: target)
            pruneBackups()
        } catch {
            Log.error("Could not create configuration backup: \(error)")
        }
    }

    private func pruneBackups() {
        let dated = backupFiles().map { url -> (URL, Date) in
            let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            return (url, modified)
        }
        guard dated.count > Self.maxBackups else { return }
        let stale = dated.sorted { ($0.1, $0.0.lastPathComponent) > ($1.1, $1.0.lastPathComponent) }.dropFirst(Self.maxBackups)
        for (url, _) in stale { try? fileManager.removeItem(at: url) }
    }
}

/// `--env-config`: read-only configuration from `MEETINGGURU_*` variables.
public final class EnvironmentConfigStore: ConfigProviding {
    private let config: AppConfig
    public var configPath: String { "Environment Variables" }
    public var isWritable: Bool { false }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var config = AppConfig(
            caldav: CalDAVConfig(
                url: environment["MEETINGGURU_CALDAV_URL"] ?? CalDAVConfig.placeholderURL,
                username: environment["MEETINGGURU_CALDAV_USERNAME"] ?? "username",
                password: environment["MEETINGGURU_CALDAV_PASSWORD"] ?? "password",
                calendarName: environment["MEETINGGURU_CALDAV_CALENDAR"] ?? "default",
                syncInterval: Int(environment["MEETINGGURU_SYNC_INTERVAL"] ?? "") ?? 60))
        config.alertAdvanceMinutes = Int(environment["MEETINGGURU_ALERT_MINUTES"] ?? "") ?? 1
        config.autoJoinDelaySeconds = Int(environment["MEETINGGURU_AUTO_JOIN_DELAY"] ?? "") ?? 5
        config.debugMode = (environment["MEETINGGURU_DEBUG"] ?? "false").lowercased() == "true"
        self.config = config
    }

    public func load() throws -> AppConfig { try config.validated() }

    public func save(_ config: AppConfig) throws {
        throw ConfigError.io("Cannot save configuration when using environment variables")
    }

    public func reset() throws -> AppConfig { config }
}
