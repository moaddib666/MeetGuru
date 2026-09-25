import Foundation

/// Runs one background calendar sync at a time; a sync stuck longer than
/// `stallTimeout` is abandoned so a fresh one can start.
@MainActor
public final class SyncManager {
    public var provider: CalendarProvider
    public var onStarted: (() -> Void)?
    public var onCompleted: ((SyncResult) -> Void)?
    public var onFailed: ((String) -> Void)?

    public private(set) var isSyncing = false
    private let stallTimeout: TimeInterval
    private let now: () -> Date
    private var startedAt: Date?
    private var generation = 0
    private var task: Task<Void, Never>?

    public init(provider: CalendarProvider, stallTimeout: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.stallTimeout = stallTimeout
        self.now = now
    }

    /// Returns false when a healthy sync is already running.
    @discardableResult
    public func startSync(range: DateInterval? = nil) -> Bool {
        if isSyncing, !abandonIfStalled() {
            Log.info("Sync already in progress, ignoring new sync request")
            return false
        }
        isSyncing = true
        startedAt = now()
        generation += 1
        let token = generation
        let provider = provider
        let window = range ?? CalDAVClient.defaultRange(now: now())
        let inviteWindow = CalDAVClient.inviteRange(now: now())
        onStarted?()
        task = Task { [weak self] in
            let outcome: Result<[MeetingEvent], Error>
            var invites: [MeetingInvite]?
            do {
                outcome = .success(try await provider.events(in: window))
                do {
                    invites = try await provider.invites(in: inviteWindow)
                } catch {
                    Log.error("Invitation check failed: \(error)")
                }
            } catch {
                outcome = .failure(error)
            }
            self?.finish(token: token, outcome: outcome, invites: invites)
        }
        return true
    }

    public func stop() {
        task?.cancel()
        task = nil
        generation += 1
        isSyncing = false
        startedAt = nil
    }

    private func finish(token: Int, outcome: Result<[MeetingEvent], Error>, invites: [MeetingInvite]?) {
        guard token == generation else {
            Log.info("Abandoned sync finished")
            return
        }
        isSyncing = false
        startedAt = nil
        task = nil
        switch outcome {
        case .success(let events):
            onCompleted?(SyncResult(events: events, syncTime: now(), invites: invites))
        case .failure(let error):
            let message = String(describing: error)
            Log.error("Calendar sync failed: \(message)")
            onFailed?(message)
        }
    }

    private func abandonIfStalled() -> Bool {
        guard let startedAt, now().timeIntervalSince(startedAt) >= stallTimeout else { return false }
        Log.error("Sync stalled for \(Int(now().timeIntervalSince(startedAt)))s, abandoning it and reconnecting")
        task?.cancel()
        task = nil
        generation += 1
        isSyncing = false
        let provider = provider
        Task { await provider.reset() }
        return true
    }
}
