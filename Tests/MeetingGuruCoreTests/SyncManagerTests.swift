import Foundation
import Testing
import os

@testable import MeetingGuruCore

actor ScriptedProvider: CalendarProvider {
    enum Step { case events([MeetingEvent]), failure(String), hang }

    private var steps: [Step]
    private(set) var calls = 0
    private(set) var resets = 0

    init(_ steps: [Step]) { self.steps = steps }

    func events(in range: DateInterval) async throws -> [MeetingEvent] {
        calls += 1
        let step = steps.isEmpty ? .events([]) : steps.removeFirst()
        switch step {
        case .events(let events): return events
        case .failure(let message): throw CalDAVError.connection(message)
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            return []
        }
    }

    func reset() { resets += 1 }
}

@MainActor
@Suite struct SyncManagerTests {
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func deliversEvents() async {
        let provider = ScriptedProvider([.events([meeting("m", startIn: 5)])])
        let manager = SyncManager(provider: provider)
        var received: SyncResult?
        manager.onCompleted = { received = $0 }
        #expect(manager.startSync())
        await waitUntil { received != nil }
        #expect(received?.events.count == 1)
        #expect(!manager.isSyncing)
    }

    @Test func unsuccessfulResultIsReportedAsFailure() async {
        let manager = SyncManager(provider: ScriptedProvider([.failure("network down")]))
        var failure: String?
        var completed = false
        manager.onFailed = { failure = $0 }
        manager.onCompleted = { _ in completed = true }
        manager.startSync()
        await waitUntil { failure != nil }
        #expect(failure?.contains("network down") == true)
        #expect(!completed)
    }

    @Test func secondRequestIgnoredWhileRunning() async {
        let provider = ScriptedProvider([.hang])
        let manager = SyncManager(provider: provider)
        #expect(manager.startSync())
        #expect(!manager.startSync())
        manager.stop()
    }

    @Test func stalledSyncIsAbandoned() async {
        var clock = referenceNow
        let provider = ScriptedProvider([.hang, .events([meeting("fresh", startIn: 5)])])
        let manager = SyncManager(provider: provider, stallTimeout: 120, now: { clock })
        var received: SyncResult?
        manager.onCompleted = { received = $0 }

        #expect(manager.startSync())
        clock = clock.addingTimeInterval(60)
        #expect(!manager.startSync())
        clock = clock.addingTimeInterval(61)
        #expect(manager.startSync())
        await waitUntil { received != nil }
        #expect(received?.events.first?.uid == "fresh")
        for _ in 0..<100 where await provider.resets == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.resets == 1)
    }
}
