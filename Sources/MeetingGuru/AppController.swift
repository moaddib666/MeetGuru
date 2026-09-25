import AppKit
import MeetingGuruCore

/// Orchestrates sync, the alert state machine, the island and the menu bar item.
/// Mirrors the Python `MeetingGuruApp` main loop: a 1 s tick picks the meeting that needs
/// attention, raises its alert once, and auto-joins after the configured delay.
@MainActor
final class AppController {
    static let wakeGap: TimeInterval = 30

    private let configStore: ConfigProviding
    private(set) var config: AppConfig
    private let stateMachine = StateMachine()
    private let sync: SyncManager
    private let island = IslandModel()
    private var islandWindow: IslandWindowController?
    private var statusItem: StatusItemController?
    private let settings: SettingsWindowController
    private let sound = SoundPlayer()
    private let demoMode: Bool
    private let tour: Bool

    private var meetings: [MeetingEvent] = []
    private var invites: [MeetingInvite] = []
    private let inviteLedger: InviteLedger
    private var announcedInvites: Set<String> = []
    private var replying: (id: String, response: InviteResponse)?
    private var lastSyncError: String?
    private var hasSynced = false
    private var dnd = DNDState()
    private var mode: IslandMode = .compact
    private var transientTimer: Timer?
    private var lastTick = Date()
    private var tickTimer: Timer?
    private var trayTimer: Timer?
    private var syncTimer: Timer?

    init(configStore: ConfigProviding, config: AppConfig, demoMode: Bool, tour: Bool = false) {
        self.configStore = configStore
        var config = config
        if tour {
            config.alertAdvanceMinutes = 1
            config.autoJoinDelaySeconds = 5
            config.notificationSound = false
        }
        self.config = config
        self.demoMode = demoMode || tour
        self.tour = tour
        inviteLedger = InviteLedger(fileURL: self.demoMode ? nil : InviteLedger.defaultURL)
        sync = SyncManager(provider: CalDAVClient(config: config.caldav))
        settings = SettingsWindowController(store: configStore)
    }

    func start() {
        island.send = { [weak self] in self?.handle($0) }
        island.primary = { [weak self] action, meeting in self?.perform(action, meeting) }
        island.secondary = { [weak self] action, meeting in self?.perform(action, meeting) }
        island.respond = { [weak self] id, response in self?.respond(to: id, with: response) }
        islandWindow = IslandWindowController(model: island)
        islandWindow?.show()

        statusItem = StatusItemController(
            handlers: .init(
                showMeeting: { [weak self] in self?.handle(.openRequested) },
                join: { [weak self] in self?.join($0, automatic: false) },
                openInvite: { [weak self] in self?.handle(.inviteOpened(id: $0.id)) },
                syncNow: { [weak self] in self?.syncNow() },
                openSettings: { [weak self] in self?.openSettings() },
                startDND: { [weak self] in self?.startDND($0) },
                stopDND: { [weak self] in self?.stopDND() },
                quit: { NSApp.terminate(nil) }))

        settings.onSaved = { [weak self] in self?.apply($0) }
        sync.onCompleted = { [weak self] in self?.syncCompleted($0) }
        sync.onFailed = { [weak self] in self?.syncFailed($0) }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info("System woke up, resyncing calendar")
                self?.syncNow()
            }
        }

        tickTimer = repeating(1) { [weak self] in self?.tick() }
        restartTimers()

        if tour {
            runTour()
        } else if demoMode {
            loadDemoData()
        } else if config.caldav.syncOnStart {
            sync.startSync()
        }
        stateMachine.initializeComplete()
        refresh()
        Log.info("MeetingGuru started")
    }

    func shutdown() {
        Log.info("Shutting down MeetingGuru")
        [tickTimer, trayTimer, syncTimer, transientTimer].forEach { $0?.invalidate() }
        sync.stop()
        sound.stop()
        islandWindow?.teardown()
        statusItem?.remove()
    }

    // MARK: - Main loop

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastTick) > Self.wakeGap {
            Log.info("Detected \(Int(now.timeIntervalSince(lastTick)))s clock gap (sleep/wake), resyncing calendar")
            syncNow()
        }
        lastTick = now

        let meeting = stateMachine.selectMeeting(from: meetings, alertAdvanceMinutes: config.alertAdvanceMinutes, now: now)
        stateMachine.setCurrentMeeting(meeting)
        if let alerted = alertFingerprint(of: mode), alerted != stateMachine.context.currentMeeting?.fingerprint {
            handle(.alertCleared)
        }

        if stateMachine.shouldShowAlert, !dnd.isActive(at: now), let current = stateMachine.context.currentMeeting {
            let firstTime = stateMachine.showAlert(at: now)
            island.backgroundIndex = Int.random(in: 0..<Assets.backgroundCount)
            handle(.alertRaised(fingerprint: current.fingerprint))
            if firstTime, config.notificationSound { sound.playAlert(volume: config.soundVolume) }
            Log.info("Meeting alert shown for: \(current.title)")
        }

        if stateMachine.shouldAutoParticipate(delaySeconds: config.autoJoinDelaySeconds, now: now),
            let current = stateMachine.context.currentMeeting
        {
            stateMachine.markAutoJoined(current.fingerprint)
            join(current, automatic: true)
        }

        if dnd.enabled, !dnd.isActive(at: now) {
            stopDND()
        }

        raiseNextInvite(now: now)

        if Int(now.timeIntervalSince1970) % 60 == 0 {
            Log.info(
                "[HEARTBEAT] meetings=\(meetings.count) current=\(stateMachine.context.currentMeeting?.title ?? "none") state=\(stateMachine.state.rawValue) sync_error=\(lastSyncError ?? "none")"
            )
        }
        refresh(now: now)
    }

    private func refresh(now: Date = Date()) {
        island.snapshot = IslandPresenter.snapshot(
            IslandInputs(
                mode: mode,
                events: meetings,
                alertMeeting: stateMachine.context.currentMeeting,
                alertShownAt: stateMachine.context.alertShownAt,
                acknowledged: stateMachine.context.acknowledged,
                autoJoinDelaySeconds: config.autoJoinDelaySeconds,
                dnd: dnd,
                syncError: lastSyncError,
                hasSynced: hasSynced || demoMode,
                now: now,
                invites: invites,
                replying: replying?.response))
        islandWindow?.islandDidResize()
    }

    private func updateTray() {
        statusItem?.update(
            schedule: MeetingSchedule(events: meetings, now: Date()),
            invites: invites,
            dnd: dnd, syncError: lastSyncError, lastSync: stateMachine.context.lastSyncTime, config: config)
    }

    // MARK: - Island

    private func handle(_ event: IslandEvent) {
        let previous = mode
        mode = IslandMachine.reduce(mode, event)
        guard mode != previous else { return }
        Log.debug("Island \(event) -> \(mode)")
        if mode.isExpanded, !previous.isExpanded, case .peek = mode {
            island.backgroundIndex = Int.random(in: 0..<Assets.backgroundCount)
        }
        transientTimer?.invalidate()
        if let duration = mode.transientDuration {
            transientTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.transientElapsed) }
            }
        }
        refresh()
    }

    /// The meeting the island is alerting on, including an alert waiting behind a notice.
    private func alertFingerprint(of mode: IslandMode) -> String? {
        switch mode {
        case .alert(let fingerprint, _), .notice(_, .alert(let fingerprint, _)): fingerprint
        default: nil
        }
    }

    private func perform(_ action: PrimaryAction, _ meeting: MeetingEvent?) {
        switch action {
        case .join, .rejoin:
            if let meeting { join(meeting, automatic: false) }
        case .syncNow:
            syncNow()
        }
    }

    private func perform(_ action: SecondaryAction, _ meeting: MeetingEvent?) {
        switch action {
        case .dismiss, .skipAlert, .done:
            if let meeting { acknowledge(meeting) } else { handle(.acknowledged) }
        case .resumeAlerts:
            stopDND()
        case .later:
            if case .invite(let id) = mode { inviteLedger.markSeen(id) }
            handle(.acknowledged)
        }
    }

    // MARK: - Invitations

    /// Pops the oldest invitation the user hasn't seen yet, but never over a meeting alert,
    /// an open card or while alerts are paused.
    private func raiseNextInvite(now: Date) {
        guard mode == .compact, replying == nil, !dnd.isActive(at: now),
            let invite = invites.first(where: { !inviteLedger.contains($0.id) })
        else { return }
        handle(.inviteRaised(id: invite.id))
        if announcedInvites.insert(invite.id).inserted {
            if config.notificationSound { sound.playInvite(volume: config.soundVolume) }
            Log.info("New invitation shown: \(invite.meeting.title)")
        }
    }

    private func respond(to id: String, with response: InviteResponse) {
        guard replying == nil, let invite = invites.first(where: { $0.id == id }) else { return }
        replying = (id, response)
        refresh()
        Log.info("Replying \(response.rawValue) to '\(invite.meeting.title)'")
        let provider = sync.provider
        let demo = demoMode
        Task { [weak self] in
            let outcome: Error?
            do {
                if demo {
                    try await Task.sleep(for: .milliseconds(700))
                } else {
                    try await provider.respond(to: invite, with: response)
                }
                outcome = nil
            } catch {
                outcome = error
            }
            self?.replyFinished(invite, response: response, error: outcome)
        }
    }

    private func replyFinished(_ invite: MeetingInvite, response: InviteResponse, error: Error?) {
        replying = nil
        if let error {
            Log.error("Reply to '\(invite.meeting.title)' failed: \(error)")
            handle(.replyFailed(.replyFailed(title: invite.meeting.title)))
            refresh()
            return
        }
        inviteLedger.markSeen(invite.id)
        invites.removeAll { $0.id == invite.id }
        if response == .declined { meetings.removeAll { $0.uid == invite.meeting.uid } }
        handle(.inviteReplied(title: invite.meeting.title, response: response))
        updateTray()
        refresh()
        if !demoMode { sync.startSync() }
    }

    private func join(_ meeting: MeetingEvent, automatic: Bool) {
        let platform = MeetingLinks.platformName(for: meeting.meetingURL)
        guard let link = meeting.meetingURL else {
            Log.error("No meeting URL found for meeting: \(meeting.title)")
            handle(.joinFailed(.noJoinLink(title: meeting.title)))
            return
        }
        guard demoMode || Browser.open(link) else {
            handle(.joinFailed(.openFailed(title: meeting.title)))
            return
        }
        logParticipation(meeting, automatic: automatic, link: link)
        if automatic {
            handle(.autoJoined(fingerprint: meeting.fingerprint))
        } else {
            stateMachine.participate(meeting.fingerprint)
            handle(.joined(title: meeting.title, platform: platform))
        }
    }

    private func acknowledge(_ meeting: MeetingEvent) {
        stateMachine.acknowledge(meeting.fingerprint)
        Log.info("Alert acknowledged: \(meeting.title)")
        handle(.acknowledged)
    }

    private func logParticipation(_ meeting: MeetingEvent, automatic: Bool, link: String) {
        let offset = meeting.timeSinceStart(at: Date())
        let timing = offset < -60 ? "early (\(Int(-offset / 60)) min)" : offset > 60 ? "late (\(Int(offset / 60)) min)" : "on time"
        Log.info("Meeting participation - '\(meeting.title)', type: \(automatic ? "auto" : "manual"), status: \(timing), url: \(link)")
    }

    // MARK: - Sync

    private func syncNow() {
        if demoMode {
            loadDemoData()
        } else {
            sync.startSync()
        }
    }

    private func syncCompleted(_ result: SyncResult) {
        meetings = result.events
        hasSynced = true
        lastSyncError = nil
        stateMachine.updateSyncTime(result.syncTime)
        stateMachine.clearError()
        stateMachine.forgetMissing(meetings)
        if let fresh = result.invites { updateInvites(fresh) }
        Log.info("Calendar sync completed: \(result.events.count) events")
        for event in result.events { Log.debug("Event: \(event.title) at \(event.start) all_day=\(event.allDay)") }
        updateTray()
        refresh()
    }

    /// Takes the server's list, keeping an invite whose reply is still in flight so its card doesn't vanish.
    private func updateInvites(_ fresh: [MeetingInvite]) {
        let pending = Set(fresh.map(\.id))
        var next = fresh
        if let answering = replying?.id, !pending.contains(answering), let current = invites.first(where: { $0.id == answering }) {
            next.append(current)
        }
        invites = next
        inviteLedger.retain(only: Set(next.map(\.id)))
        switch mode {
        case .invite(let id) where !pending.contains(id) && id != replying?.id,
            .notice(_, .invite(let id)) where !pending.contains(id) && id != replying?.id:
            handle(.inviteCleared)
        default: break
        }
    }

    private func syncFailed(_ message: String) {
        lastSyncError = message
        updateTray()
        refresh()
    }

    private func loadDemoData() {
        let now = Date()
        let demo = MeetingEvent(
            uid: "demo-meeting-1",
            title: "Demo Team Standup",
            start: now.addingTimeInterval(30),
            end: now.addingTimeInterval(30 * 60 + 30),
            location: "https://meet.google.com/demo-meeting",
            details: "Daily standup meeting for the demo team",
            organizer: "demo@example.com",
            attendees: ["user@example.com", "demo@example.com"])
        let later = MeetingEvent(
            uid: "demo-meeting-2", title: "Design review", start: now.addingTimeInterval(2 * 3600),
            end: now.addingTimeInterval(3 * 3600), location: "Room 4 https://zoom.us/j/123")
        let invited = MeetingEvent(
            uid: "demo-invite-1", title: "Roadmap review with product", start: now.addingTimeInterval(26 * 3600),
            end: now.addingTimeInterval(27 * 3600), location: "https://meet.google.com/demo-invite", organizer: "dana@example.com")
        let invite = MeetingInvite(
            id: "demo-invite-1|0", meeting: invited, organizerName: "Dana Smith",
            resource: URL(string: "https://caldav.example.com/demo-invite-1.ics")!)
        let demoInvites = invites.isEmpty && !inviteLedger.contains(invite.id) ? [invite] : invites
        syncCompleted(SyncResult(events: [demo, later], syncTime: now, invites: demoInvites))
    }

    /// A scripted walk through the island for the README recording: peek, a new invite
    /// answered with Accept, then a meeting alert that auto-joins. Quits when done.
    private func runTour() {
        let start = Date()
        let standup = MeetingEvent(
            uid: "tour-standup", title: "Platform standup", start: start.addingTimeInterval(71),
            end: start.addingTimeInterval(71 + 30 * 60), location: "https://meet.google.com/abc-defg-hij")
        let planning = MeetingEvent(
            uid: "tour-planning", title: "Quarterly planning", start: start.addingTimeInterval(95 * 60),
            end: start.addingTimeInterval(155 * 60), location: "Kyiv office")
        let invite = MeetingInvite(
            id: "tour-invite",
            meeting: MeetingEvent(
                uid: "tour-invite", title: "Roadmap review with product", start: start.addingTimeInterval(26 * 3600),
                end: start.addingTimeInterval(27 * 3600), location: "https://meet.google.com/xyz-abcd-efg",
                organizer: "dana@example.com"),
            organizerName: "Dana Smith", resource: URL(string: "https://caldav.example.com/tour-invite.ics")!)
        syncCompleted(SyncResult(events: [standup, planning], syncTime: start, invites: []))

        let steps: [(TimeInterval, () -> Void)] = [
            (0.6, { self.handle(.openRequested) }),
            (3.8, { self.handle(.clickedOutside) }),
            (5.0, { self.syncCompleted(SyncResult(events: [standup, planning], syncTime: Date(), invites: [invite])) }),
            (8.0, { self.respond(to: invite.id, with: .accepted) }),
            (19.0, { self.perform(.done, standup) }),
            (21.0, { NSApp.terminate(nil) }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(step) }
        }
    }

    // MARK: - DND

    private func startDND(_ duration: DNDDuration) {
        dnd.start(duration, at: Date())
        Log.info("DND mode started with duration: \(duration.rawValue)")
        updateTray()
        refresh()
    }

    private func stopDND() {
        dnd.stop()
        Log.info("DND mode stopped")
        updateTray()
        refresh()
    }

    // MARK: - Settings

    private func openSettings() {
        settings.show(config: config)
    }

    private func apply(_ newConfig: AppConfig) {
        let caldavChanged = newConfig.caldav != config.caldav
        config = newConfig
        Log.configure(debug: Log.isDebug || newConfig.debugMode, echo: true)
        TrayIcon.clearCache()
        if caldavChanged {
            sync.stop()
            sync.provider = CalDAVClient(config: newConfig.caldav)
        }
        restartTimers()
        syncNow()
        updateTray()
        Log.info("Configuration updated")
    }

    private func restartTimers() {
        trayTimer?.invalidate()
        syncTimer?.invalidate()
        trayTimer = repeating(TimeInterval(config.trayUpdateInterval)) { [weak self] in self?.updateTray() }
        if !demoMode {
            syncTimer = repeating(TimeInterval(config.caldav.syncInterval)) { [weak self] in self?.sync.startSync() }
        }
        updateTray()
    }

    private func repeating(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated(body) }
        timer.tolerance = min(0.1, interval / 10)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
