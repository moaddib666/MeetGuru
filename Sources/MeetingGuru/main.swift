import AppKit
import MeetingGuruCore

let version = "2.0.0"

struct Options {
    var debug = false
    var envConfig = false
    var configPath: String?
    var showVersion = false
    var showConfig = false
    var demoMode = false
    var demoTour = false
    var syncOnce = false
    var galleryDirectory: String?
    var help = false
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--debug", "-d": options.debug = true
        case "--env-config", "-e": options.envConfig = true
        case "--config", "-c": options.configPath = iterator.next()
        case "--version", "-v": options.showVersion = true
        case "--show-config": options.showConfig = true
        case "--demo-mode": options.demoMode = true
        case "--demo-tour": options.demoTour = true
        case "--sync-once": options.syncOnce = true
        case "--render-gallery": options.galleryDirectory = iterator.next()
        case "--help", "-h": options.help = true
        default:
            if argument.hasPrefix("-psn_") { continue }
            FileHandle.standardError.write(Data("Ignoring unknown argument: \(argument)\n".utf8))
        }
    }
    return options
}

let usage = """
    usage: MeetingGuru [-h] [--debug] [--env-config] [--config PATH] [--version] [--show-config] [--demo-mode] [--demo-tour]
                       [--sync-once] [--render-gallery DIR]

    MeetingGuru - Intelligent meeting management with CalDAV integration

      -d, --debug          Enable debug logging
      -e, --env-config     Use environment variables for configuration
      -c, --config PATH    Path to configuration file
      -v, --version        Show version information
      --show-config        Show current configuration and exit
      --demo-mode          Run with sample demo meetings for testing UI
      --demo-tour          Play a scripted ~20 s tour of the island, then quit
      --sync-once          Fetch the calendar once, print the meetings and invitations and exit
      --render-gallery DIR Render every island state to PNG files in DIR and exit
    """

let options = parseOptions(CommandLine.arguments)
Log.configure(debug: options.debug, echo: options.debug || isatty(STDERR_FILENO) == 1)

if options.help {
    print(usage)
    exit(0)
}
if options.showVersion {
    print("MeetingGuru \(version)")
    exit(0)
}

let store: ConfigProviding =
    options.envConfig
    ? EnvironmentConfigStore()
    : options.configPath.map { ConfigStore(fileURL: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) } ?? ConfigStore()

func loadConfig() -> AppConfig {
    do {
        return try store.load()
    } catch {
        FileHandle.standardError.write(Data("Initialization failed: \(error)\n".utf8))
        exit(1)
    }
}

if options.showConfig {
    let config = loadConfig()
    print("Configuration file: \(store.configPath)")
    print("Configuration:")
    print((try? config.redactedJSON()) ?? "{}")
    exit(0)
}

if options.syncOnce {
    let config = loadConfig()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        let client = CalDAVClient(config: config.caldav)
        do {
            let events = try await client.events(in: CalDAVClient.defaultRange(now: Date()))
            print("Synced \(events.count) events")
            for event in events {
                let link = MeetingLinks.platformName(for: event.meetingURL) ?? "no link"
                print(
                    "\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(Formatting.clock(event.end))\(event.allDay ? " [all-day]" : "")  \(event.title)  (\(link))"
                )
            }
            let invites = try await client.invites(in: CalDAVClient.inviteRange(now: Date()))
            print("\(invites.count) invitation(s) waiting for an answer (as \(await client.addresses.sorted().joined(separator: ", ")))")
            for invite in invites {
                let from = invite.from.map { "  from \($0)" } ?? ""
                print(
                    "\(Formatting.dayAndTime(invite.meeting, now: Date()))  \(invite.meeting.title)\(invite.isRecurring ? " [repeats]" : "")\(from)")
            }
        } catch {
            print("Sync failed: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

let app = NSApplication.shared

if let directory = options.galleryDirectory {
    MainActor.assumeIsolated {
        Gallery.render(to: URL(fileURLWithPath: directory))
    }
    exit(0)
}

let config = loadConfig()
if config.debugMode { Log.configure(debug: true, echo: true) }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let controller = AppController(
                configStore: store, config: config, demoMode: options.demoMode, tour: options.demoTour)
            controller.start()
            self.controller = controller
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { controller?.shutdown() }
    }
}

let signalSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
