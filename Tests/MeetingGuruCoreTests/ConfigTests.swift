import Foundation
import Testing

@testable import MeetingGuruCore

@Suite struct ConfigCompatibilityTests {
    let fixture = Bundle.module.url(forResource: "python_config", withExtension: "json", subdirectory: "Fixtures")!

    @Test func readsTheFileThePythonAppWrites() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: fixture)).validated()
        #expect(config.caldav.url == "https://dav.privateemail.com/")
        #expect(config.caldav.password == "not-a-real-password")
        #expect(config.caldav.token == nil)
        #expect(config.soundVolume == 0.6)
        #expect(config.trayColorAlert == "#ff4500")
    }

    @Test func writesTheSameKeysAsPydantic() throws {
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: fixture))
        let written = try JSONSerialization.jsonObject(with: ConfigStore.encoder.encode(config)) as! [String: Any]
        #expect(Set(written.keys) == Set(original.keys))
        let caldav = written["caldav"] as! [String: Any]
        #expect(Set(caldav.keys) == Set((original["caldav"] as! [String: Any]).keys))
        #expect(caldav["token"] is NSNull, "optional fields are written as null, like pydantic")
        #expect(NSDictionary(dictionary: written).isEqual(to: original))
    }

    @Test func slashesAreNotEscaped() throws {
        let text = String(decoding: try ConfigStore.encoder.encode(AppConfig.placeholder), as: UTF8.self)
        #expect(text.contains("\"https://caldav.example.com/\""))
    }

    @Test func missingOptionalKeysTakeDefaults() throws {
        let json = #"{"caldav": {"url": "https://dav.example.com", "username": "u", "password": "p"}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)).validated()
        #expect(config.caldav.url == "https://dav.example.com/")
        #expect(config.caldav.syncInterval == 60)
        #expect(config.alertAdvanceMinutes == 1)
        #expect(config.autoJoinDelaySeconds == 5)
        #expect(config.trayColorOk == "#00FF00")
    }

    @Test(arguments: [
        #"{"caldav": {"url": "ftp://x", "username": "u", "password": "p"}}"#,
        #"{"caldav": {"url": "https://x/", "username": "u"}}"#,
        #"{"caldav": {"url": "https://x/", "username": "u", "password": "p", "timeout": 0}}"#,
        #"{"caldav": {"url": "https://x/", "username": "u", "password": "p", "sync_interval": 4}}"#,
        #"{"caldav": {"url": "https://x/", "username": "u", "password": "p"}, "alert_advance_minutes": 61}"#,
        #"{"caldav": {"url": "https://x/", "username": "u", "password": "p"}, "auto_join_delay_seconds": -1}"#,
        #"{"caldav": {"url": "https://x/", "username": "u", "password": "p"}, "sound_volume": 1.5}"#,
    ])
    func rejectsWhatPydanticRejects(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)).validated()
        }
    }

    @Test func placeholderNeedsNoCredentials() throws {
        var config = AppConfig.placeholder
        config.caldav.password = nil
        #expect(try config.validated() == config)
    }

    @Test func tokenAloneIsEnough() throws {
        let config = CalDAVConfig(url: "https://x/", username: "u", token: "t")
        #expect(throws: Never.self) { try config.validated() }
    }
}

@Suite struct ConfigStoreTests {
    @Test func missingFileCreatesTheDefault() throws {
        let store = ConfigStore(directory: temporaryDirectory())
        #expect(try store.load() == AppConfig.placeholder)
        #expect(store.exists)
    }

    @Test func roundTripsAndBacksUpBeforeOverwriting() throws {
        let store = ConfigStore(directory: temporaryDirectory())
        var config = AppConfig(caldav: CalDAVConfig(url: "https://dav.example.com", username: "me", password: "pw"))
        config.soundVolume = 0.25
        try store.save(config)
        let loaded = try store.load()
        #expect(loaded.caldav.url == "https://dav.example.com/")
        #expect(loaded.soundVolume == 0.25)

        try store.save(loaded)
        #expect(store.backupFiles().count == 1)
        #expect(store.backupFiles().first?.lastPathComponent.hasPrefix("config.backup_") == true)
    }

    @Test func savedFileIsPrivateToTheUser() throws {
        let store = ConfigStore(directory: temporaryDirectory())
        try store.save(AppConfig.placeholder)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.configPath)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func corruptFileIsBackedUpAndReplaced() throws {
        let directory = temporaryDirectory()
        let store = ConfigStore(directory: directory)
        try Data("{ not json".utf8).write(to: store.fileURL)
        #expect(try store.load() == AppConfig.placeholder)
        let backup = try #require(store.backupFiles().first)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
    }

    @Test func keepsOnlyTheFiveNewestBackups() throws {
        var tick = 0.0
        let store = ConfigStore(
            directory: temporaryDirectory(),
            now: {
                tick += 1
                return Date(timeIntervalSince1970: 1_790_000_000 + tick)
            })
        for _ in 0..<9 { try store.save(AppConfig.placeholder) }
        #expect(store.backupFiles().count == ConfigStore.maxBackups)
    }

    @Test func customFileNameKeepsPythonBackupNaming() throws {
        let file = temporaryDirectory().appendingPathComponent("work.json")
        let store = ConfigStore(fileURL: file)
        try store.save(AppConfig.placeholder)
        try store.save(AppConfig.placeholder)
        #expect(store.backupFiles().first?.lastPathComponent.hasPrefix("work.backup_") == true)
    }

    @Test func resetWritesThePlaceholder() throws {
        let store = ConfigStore(directory: temporaryDirectory())
        try store.save(AppConfig(caldav: CalDAVConfig(url: "https://x/", username: "me", password: "pw")))
        #expect(try store.reset() == AppConfig.placeholder)
        #expect(try store.load() == AppConfig.placeholder)
    }

    @Test func environmentConfig() throws {
        let store = EnvironmentConfigStore(environment: [
            "MEETINGGURU_CALDAV_URL": "https://env.example.com",
            "MEETINGGURU_CALDAV_USERNAME": "env",
            "MEETINGGURU_CALDAV_PASSWORD": "secret",
            "MEETINGGURU_ALERT_MINUTES": "3",
            "MEETINGGURU_DEBUG": "TRUE",
        ])
        let config = try store.load()
        #expect(config.caldav.url == "https://env.example.com/")
        #expect(config.alertAdvanceMinutes == 3)
        #expect(config.debugMode)
        #expect(!store.isWritable)
        #expect(throws: ConfigError.self) { try store.save(config) }
    }

    @Test func redactedDumpHidesSecrets() throws {
        let config = AppConfig(caldav: CalDAVConfig(url: "https://x/", username: "me", password: "hunter2", token: "tok"))
        let text = try config.redactedJSON()
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("\"tok\""))
        #expect(text.contains("***hidden***"))
    }
}
