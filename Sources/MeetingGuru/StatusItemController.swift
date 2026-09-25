import AppKit
import MeetingGuruCore
import SwiftUI

/// The menu bar icon: the tinted mascot, its tooltip and menu. The menu opens on a small
/// black island card with the next meeting, then the upcoming meetings (click to join),
/// then the same actions the Python tray offered.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Handlers {
        var showMeeting: () -> Void
        var join: (MeetingEvent) -> Void
        var openInvite: (MeetingInvite) -> Void
        var syncNow: () -> Void
        var openSettings: () -> Void
        var startDND: (DNDDuration) -> Void
        var stopDND: () -> Void
        var quit: () -> Void
    }

    static let listedMeetings = 6

    static let autosaveName = "MeetingGuru"
    /// Distance from the right screen edge for the first launch. A crowded menu bar hides
    /// new items at its left end, so start among the system icons; ⌘-drag moves it and
    /// macOS remembers the spot under the same key.
    static let initialPosition: Double = 260

    private let item: NSStatusItem = {
        let key = "NSStatusItem Preferred Position \(StatusItemController.autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(StatusItemController.initialPosition, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = StatusItemController.autosaveName
        item.behavior = []
        return item
    }()
    private let handlers: Handlers
    private let menu = NSMenu()
    private let dndMenu = NSMenu(title: "Do Not Disturb")
    private var schedule = MeetingSchedule(events: [], now: Date())
    private var invites: [MeetingInvite] = []
    private var dnd = DNDState()
    private var syncError: String?
    private var lastSync: Date?
    private var joinable: [String: MeetingEvent] = [:]

    init(handlers: Handlers) {
        self.handlers = handlers
        super.init()
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("MeetingGuru")
        menu.autoenablesItems = false
        menu.delegate = self
        dndMenu.autoenablesItems = false
        dndMenu.delegate = self
        item.menu = menu
    }

    func update(schedule: MeetingSchedule, invites: [MeetingInvite], dnd: DNDState, syncError: String?, lastSync: Date?, config: AppConfig) {
        self.schedule = schedule
        self.invites = invites
        self.dnd = dnd
        self.syncError = syncError
        self.lastSync = lastSync
        let status = schedule.trayStatus(dndActive: dnd.isActive(at: schedule.now))
        item.button?.image = TrayIcon.image(hex: status.colorHex(for: config))
        let waiting = invites.isEmpty ? "" : "\n\(invites.count) invitation\(invites.count == 1 ? "" : "s") waiting for your answer"
        item.button?.toolTip = schedule.tooltip(syncError: syncError, dnd: dnd) + waiting
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === dndMenu { buildDNDMenu() } else if menu === self.menu { buildMainMenu() }
    }

    private func buildMainMenu() {
        menu.removeAllItems()
        let now = Date()
        let live = MeetingSchedule(events: schedule.current + schedule.upcoming, now: now)

        let header = NSMenuItem()
        let headerView = NSHostingView(
            rootView: MenuHeaderView(
                meeting: live.featured, now: now, dnd: dnd, syncError: syncError,
                urgency: Urgency.make(schedule: live, dndActive: dnd.isActive(at: now))))
        headerView.frame = NSRect(x: 0, y: 0, width: 300, height: 50)
        header.view = headerView
        menu.addItem(header)

        let listed = Array((live.current + live.upcoming).prefix(Self.listedMeetings))
        joinable = [:]
        if !listed.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Upcoming"))
            for meeting in listed { menu.addItem(meetingItem(meeting, now: now)) }
        }

        if !invites.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Invitations"))
            for invite in invites.prefix(Self.listedMeetings) { menu.addItem(inviteItem(invite, now: now)) }
        }

        menu.addItem(.separator())
        menu.addItem(action("Show Meeting", #selector(showMeeting), symbol: "rectangle.portrait.and.arrow.right"))
        let sync = action("Sync Now", #selector(syncNow), key: "r", symbol: "arrow.triangle.2.circlepath")
        setSubtitle(sync, syncSubtitle(now: now))
        menu.addItem(sync)
        let dndItem = NSMenuItem(title: "Do Not Disturb", action: nil, keyEquivalent: "")
        dndItem.image = symbol(dnd.isActive(at: now) ? "moon.fill" : "moon")
        dndItem.submenu = dndMenu
        if let summary = dnd.summary(at: now) { setSubtitle(dndItem, "Alerts paused · \(summary)") }
        menu.addItem(dndItem)
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(action("Quit MeetingGuru", #selector(quit), key: "q", symbol: "power"))
    }

    private func buildDNDMenu() {
        dndMenu.removeAllItems()
        let now = Date()
        if dnd.isActive(at: now) {
            let status: String
            if dnd.duration == .untilResume {
                status = dnd.elapsed(at: now).map { "Paused for \(Formatting.shortDuration($0))" } ?? "Paused until you resume"
            } else {
                status = dnd.remaining(at: now).map { "Paused · \(Formatting.shortDuration($0)) left" } ?? "Paused"
            }
            let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            header.isEnabled = false
            dndMenu.addItem(header)
            dndMenu.addItem(.separator())
            dndMenu.addItem(action("Resume Alerts", #selector(stopDND), symbol: "bell"))
        } else {
            for duration in DNDDuration.allCases {
                let entry = action(duration.label, #selector(startDND(_:)))
                entry.representedObject = duration.rawValue
                dndMenu.addItem(entry)
            }
        }
    }

    private func meetingItem(_ meeting: MeetingEvent, now: Date) -> NSMenuItem {
        let isLive = meeting.status(at: now) == .current
        let title = "\(Formatting.clock(meeting.start))   \(meeting.title)"
        let entry = NSMenuItem(title: title, action: #selector(joinMeeting(_:)), keyEquivalent: "")
        entry.target = self
        let hasLink = meeting.meetingURL != nil
        entry.isEnabled = hasLink
        entry.image = symbol(isLive ? "record.circle" : hasLink ? "video" : "calendar")
        var detail = [String]()
        if isLive { detail.append("Now · \(Formatting.shortDuration(meeting.end.timeIntervalSince(now))) left") }
        if let place = IslandPresenter.place(for: meeting) { detail.append(place) }
        if !hasLink { detail.append("No join link") }
        setSubtitle(entry, detail.joined(separator: " · "))
        entry.toolTip = hasLink ? "Join \(meeting.title)" : nil
        entry.representedObject = meeting.fingerprint
        joinable[meeting.fingerprint] = meeting
        return entry
    }

    private func inviteItem(_ invite: MeetingInvite, now: Date) -> NSMenuItem {
        let entry = NSMenuItem(title: invite.meeting.title, action: #selector(openInvite(_:)), keyEquivalent: "")
        entry.target = self
        entry.image = symbol("envelope.badge")
        let from = invite.from.map { " · from \($0)" } ?? ""
        setSubtitle(entry, Formatting.dayAndTime(invite.meeting, now: now) + from)
        entry.toolTip = "Accept, decline or answer maybe on the island"
        entry.representedObject = invite.id
        return entry
    }

    private func syncSubtitle(now: Date) -> String? {
        if let syncError { return "Last sync failed: \(syncError.prefix(60))" }
        guard let lastSync else { return "Not synced yet" }
        return "Synced \(Formatting.clock(lastSync))"
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func setSubtitle(_ entry: NSMenuItem, _ text: String?) {
        guard let text, !text.isEmpty else { return }
        if #available(macOS 14.4, *) { entry.subtitle = text }
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", symbol name: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        if let name { entry.image = symbol(name) }
        return entry
    }

    @objc private func showMeeting() { handlers.showMeeting() }
    @objc private func syncNow() { handlers.syncNow() }
    @objc private func openSettings() { handlers.openSettings() }
    @objc private func stopDND() { handlers.stopDND() }
    @objc private func quit() { handlers.quit() }

    @objc private func joinMeeting(_ sender: NSMenuItem) {
        guard let fingerprint = sender.representedObject as? String, let meeting = joinable[fingerprint] else { return }
        handlers.join(meeting)
    }

    @objc private func openInvite(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let invite = invites.first(where: { $0.id == id }) else { return }
        handlers.openInvite(invite)
    }

    @objc private func startDND(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let duration = DNDDuration(rawValue: raw) else { return }
        handlers.startDND(duration)
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}

/// The next meeting at the top of the menu, in native menu colours.
struct MenuHeaderView: View {
    let meeting: MeetingEvent?
    let now: Date
    let dnd: DNDState
    let syncError: String?
    let urgency: Urgency

    var body: some View {
        HStack(spacing: 10) {
            Mascot(size: 20, color: urgency.glows ? Palette.urgency(urgency) : .primary)
                .opacity(urgency == .paused ? 0.4 : 1)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var headline: String {
        meeting?.title ?? "No meetings ahead"
    }

    private var detail: String {
        if let summary = dnd.summary(at: now) { return "Alerts paused · \(summary)" }
        if syncError != nil { return "Sync failed · showing the last copy" }
        guard let meeting else { return "Your next two days are clear" }
        if meeting.status(at: now) == .current {
            return "Now · \(Formatting.shortDuration(meeting.end.timeIntervalSince(now))) left · \(Formatting.timeRange(meeting))"
        }
        return "in \(Formatting.shortDuration(max(60, meeting.timeToStart(at: now)))) · \(Formatting.timeRange(meeting))"
    }

    private var detailColor: Color {
        if dnd.isActive(at: now) { return Palette.brass }
        if syncError != nil { return Palette.coral }
        return urgency.glows ? Palette.urgency(urgency) : .secondary
    }
}
