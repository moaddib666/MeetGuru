import AppKit
import MeetingGuruCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    var onSaved: ((AppConfig) -> Void)?
    private let store: ConfigProviding
    private var window: NSWindow?

    init(store: ConfigProviding) {
        self.store = store
    }

    func show(config: AppConfig) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            draft: config,
            store: store,
            onSave: { [weak self] saved in
                self?.onSaved?(saved)
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "MeetingGuru Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.delegate = self
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

private enum Preset: String, CaseIterable, Identifiable {
    case google = "Google Calendar", icloud = "iCloud", nextcloud = "Nextcloud", privateEmail = "PrivateEmail"

    var id: String { rawValue }

    var url: String {
        switch self {
        case .google: "https://apidata.googleusercontent.com/caldav/v2/"
        case .icloud: "https://caldav.icloud.com/"
        case .nextcloud: "https://your-nextcloud.com/remote.php/dav/calendars/username/"
        case .privateEmail: "https://dav.privateemail.com/"
        }
    }

    var hint: String {
        switch self {
        case .google: "Enter your Gmail address as the username and an App Password."
        case .icloud: "Use your Apple ID as the username and an app-specific password."
        case .nextcloud: "Replace “your-nextcloud.com” and “username” in the server URL."
        case .privateEmail: "Use your PrivateEmail address as the username and your account password."
        }
    }
}

enum TestState: Equatable {
    case idle, running, passed(String), failed(String)
}

struct SettingsView: View {
    @State var draft: AppConfig
    let store: ConfigProviding
    let onSave: (AppConfig) -> Void
    let onCancel: () -> Void

    @State var tab = 0
    @State private var hint: String?
    @State private var test: TestState = .idle
    @State private var saveError: String?
    @State private var confirmReset = false
    @State private var sound = SoundPlayer()

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(test: test)
            TabView(selection: $tab) {
                calendarTab.tabItem { Label("Calendar", systemImage: "calendar") }.tag(0)
                alertsTab.tabItem { Label("Alerts", systemImage: "bell.badge") }.tag(1)
                menuBarTab.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }.tag(2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(spacing: 10) {
                Button("Reset to Defaults…", role: .destructive) { confirmReset = true }
                    .disabled(!store.isWritable)
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(2)
                } else if !store.isWritable {
                    Text("Using environment variables — changes can’t be saved.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.isWritable)
            }
            .padding(16)
        }
        .frame(width: 580, height: 640)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { reset() }
        } message: {
            Text("Your current configuration is backed up next to config.json before it’s overwritten.")
        }
    }

    // MARK: Calendar

    private var calendarTab: some View {
        Form {
            Section {
                TextField("Server URL", text: $draft.caldav.url, prompt: Text("https://dav.example.com/"))
                TextField("Username", text: $draft.caldav.username, prompt: Text("you@example.com"))
                SecureField("Password", text: optional(\.caldav.password))
                SecureField("Token", text: optional(\.caldav.token), prompt: Text("Optional — used instead of the password"))
                TextField("Calendar", text: $draft.caldav.calendarName, prompt: Text("default"))
            } header: {
                HStack {
                    Text("CalDAV server")
                    Spacer()
                    Menu("Fill in for…") {
                        ForEach(Preset.allCases) { preset in
                            Button(preset.rawValue) { apply(preset) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } footer: {
                if let hint { Text(hint).foregroundStyle(.secondary) }
            }

            Section("Connection") {
                Stepper(value: $draft.caldav.syncInterval, in: 5...3600, step: 5) {
                    LabeledContent("Sync every", value: "\(draft.caldav.syncInterval) s")
                }
                Stepper(value: $draft.caldav.timeout, in: 1...300) {
                    LabeledContent("Timeout", value: "\(draft.caldav.timeout) s")
                }
                Toggle("Sync when MeetingGuru starts", isOn: $draft.caldav.syncOnStart)
                Toggle("Verify SSL certificates", isOn: $draft.caldav.verifySSL)
                Toggle("Cache events locally", isOn: $draft.caldav.useCache)
                HStack {
                    Button("Test Connection") { runTest() }
                        .disabled(test == .running)
                    testStatus
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch test {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
        }
    }

    // MARK: Alerts

    private var alertsTab: some View {
        Form {
            Section("Timing") {
                Stepper(value: $draft.alertAdvanceMinutes, in: 1...60) {
                    LabeledContent("Alert before a meeting", value: "\(draft.alertAdvanceMinutes) min")
                }
                Stepper(value: $draft.autoJoinDelaySeconds, in: 0...60) {
                    LabeledContent(
                        "Join automatically after", value: draft.autoJoinDelaySeconds == 0 ? "immediately" : "\(draft.autoJoinDelaySeconds) s")
                }
                Stepper(value: $draft.trayUpdateInterval, in: 1...300) {
                    LabeledContent("Refresh menu bar icon every", value: "\(draft.trayUpdateInterval) s")
                }
                Toggle("Show missed meetings", isOn: $draft.showMissedMeetings)
            }
            Section {
                HStack(spacing: 18) {
                    GlowSwatch(urgency: .upcoming, label: "15 min")
                    GlowSwatch(urgency: .soon, label: "5 min")
                    GlowSwatch(urgency: .now, label: "1 min")
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Island")
            } footer: {
                Text(
                    "The island glows blue, then orange, then red as the next meeting approaches. The alert opens \(draft.alertAdvanceMinutes) min before it starts; hover the island any time to see the day."
                )
                .foregroundStyle(.secondary)
            }
            Section("Sound") {
                Toggle("Play a sound when an alert appears", isOn: $draft.notificationSound)
                LabeledContent("Volume") {
                    Slider(value: $draft.soundVolume, in: 0...1) { editing in
                        if !editing { sound.playAlert(volume: draft.soundVolume) }
                    }
                    .frame(width: 200)
                    Text("\(Int((draft.soundVolume * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                .disabled(!draft.notificationSound)
            }
            Section("Diagnostics") {
                Toggle("Debug logging", isOn: $draft.debugMode)
                LabeledContent("Configuration file") {
                    Text(store.configPath).textSelection(.enabled).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Menu bar

    private var menuBarTab: some View {
        Form {
            Section {
                colorRow("No meetings", \.trayColorDefault, "Nothing left on today’s calendar")
                colorRow("Meeting in progress", \.trayColorAlert, "A meeting is running right now")
                colorRow("Meeting soon", \.trayColorWarning, "The next meeting starts within 15 minutes")
                colorRow("Meetings later", \.trayColorOk, "Meetings are scheduled but not imminent")
            } header: {
                Text("Menu bar icon colours")
            } footer: {
                Text("While alerts are paused the icon turns grey.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func colorRow(_ title: String, _ key: WritableKeyPath<AppConfig, String>, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: TrayIcon.image(hex: draft[keyPath: key]))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(nsColor: NSColor(hex: draft[keyPath: key]) ?? .white) },
                    set: { draft[keyPath: key] = NSColor($0).hexString }
                ), supportsOpacity: false
            )
            .labelsHidden()
        }
    }

    // MARK: Actions

    private func optional(_ key: WritableKeyPath<AppConfig, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: key] ?? "" },
            set: { draft[keyPath: key] = $0.isEmpty ? nil : $0 })
    }

    private func apply(_ preset: Preset) {
        draft.caldav.url = preset.url
        draft.caldav.username = ""
        draft.caldav.password = nil
        draft.caldav.token = nil
        draft.caldav.calendarName = "default"
        draft.caldav.verifySSL = true
        hint = preset.hint
    }

    private func trimmedDraft() -> AppConfig {
        var config = draft
        config.caldav.url = config.caldav.url.trimmingCharacters(in: .whitespaces)
        config.caldav.username = config.caldav.username.trimmingCharacters(in: .whitespaces)
        config.caldav.password = config.caldav.password?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        config.caldav.token = config.caldav.token?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        config.caldav.calendarName = config.caldav.calendarName.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "default"
        return config
    }

    private func runTest() {
        let candidate = trimmedDraft().caldav
        if candidate.url.isEmpty { test = .failed("Enter a server URL"); return }
        if candidate.username.isEmpty { test = .failed("Enter a username"); return }
        if candidate.password == nil, candidate.token == nil { test = .failed("Enter a password or token"); return }
        let validated: CalDAVConfig
        do {
            validated = try candidate.validated()
        } catch {
            test = .failed("\(error)")
            return
        }
        test = .running
        Task {
            let result = await CalDAVClient(config: validated).testConnection()
            test = result.ok ? .passed(result.message) : .failed(result.message)
        }
    }

    private func save() {
        do {
            let config = try trimmedDraft().validated()
            try store.save(config)
            saveError = nil
            onSave(config)
        } catch {
            saveError = "\(error)"
        }
    }

    private func reset() {
        do {
            draft = try store.reset()
            saveError = nil
            hint = nil
            test = .idle
        } catch {
            saveError = "\(error)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Black band across the top of Settings: the island's identity plus the connection state.
private struct SettingsHeader: View {
    let test: TestState

    var body: some View {
        HStack(spacing: 14) {
            Mascot(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("MeetingGuru")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Version \(version) · Alerts from your CalDAV calendar")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(Color.black.ignoresSafeArea(edges: .top))
        .environment(\.colorScheme, .dark)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) =
            switch test {
            case .idle: ("Connection not checked", Palette.faint)
            case .running: ("Checking…", Palette.brass)
            case .passed: ("Connected", Color.green)
            case .failed: ("Can’t connect", Palette.coral)
            }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(color == Palette.faint ? Palette.dim : color)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// A miniature collapsed island showing one urgency colour.
private struct GlowSwatch: View {
    let urgency: Urgency
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .trailing) {
                SideIslandShape(shoulder: 5, radius: 6)
                    .fill(Color.black)
                    .shadow(color: Palette.urgency(urgency).opacity(0.9), radius: 7)
                Mascot(size: 11, color: Palette.urgency(urgency))
                    .padding(.trailing, 5)
            }
            .frame(width: 26, height: 28)
            .padding(.horizontal, 8)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Glows \(label) before a meeting")
    }
}
