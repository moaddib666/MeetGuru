import Foundation
import Testing

@testable import MeetingGuruCore

@Suite struct IslandMachineTests {
    typealias M = IslandMachine
    let notice = IslandNotice.noJoinLink(title: "Chat")

    @Test func hoverOpensAndClosesAPeek() {
        #expect(M.reduce(.compact, .hoverEntered) == .peek(pinned: false))
        #expect(M.reduce(.peek(pinned: false), .hoverExited) == .compact)
    }

    @Test func clickPinsThePeekUntilDismissed() {
        #expect(M.reduce(.compact, .clicked) == .peek(pinned: true))
        #expect(M.reduce(.peek(pinned: false), .clicked) == .peek(pinned: true))
        #expect(M.reduce(.peek(pinned: true), .hoverExited) == .peek(pinned: true))
        #expect(M.reduce(.peek(pinned: true), .clickedOutside) == .compact)
        #expect(M.reduce(.peek(pinned: true), .clicked) == .compact)
        #expect(M.reduce(.peek(pinned: true), .escapePressed) == .compact)
    }

    @Test func menuOpenPinsThePeek() {
        #expect(M.reduce(.compact, .openRequested) == .peek(pinned: true))
    }

    @Test func alertsWinFromEveryState() {
        let alert = IslandMode.alert(fingerprint: "a", autoJoined: false)
        for mode: IslandMode in [
            .compact, .peek(pinned: false), .peek(pinned: true), .joining(title: "x", platform: nil), .notice(notice, resume: .compact),
        ] {
            #expect(M.reduce(mode, .alertRaised(fingerprint: "a")) == alert)
        }
        #expect(M.reduce(.alert(fingerprint: "a", autoJoined: true), .alertRaised(fingerprint: "b")) == .alert(fingerprint: "b", autoJoined: false))
        #expect(M.reduce(.alert(fingerprint: "a", autoJoined: true), .alertRaised(fingerprint: "a")) == .alert(fingerprint: "a", autoJoined: true))
    }

    @Test func alertsIgnoreHoverAndStrayClicks() {
        let alert = IslandMode.alert(fingerprint: "a", autoJoined: false)
        for event: IslandEvent in [.hoverEntered, .hoverExited, .clicked, .clickedOutside, .escapePressed, .transientElapsed] {
            #expect(M.reduce(alert, event) == alert)
        }
    }

    @Test func autoJoinKeepsTheAlertOpen() {
        #expect(M.reduce(.alert(fingerprint: "a", autoJoined: false), .autoJoined(fingerprint: "a")) == .alert(fingerprint: "a", autoJoined: true))
        #expect(M.reduce(.alert(fingerprint: "a", autoJoined: false), .autoJoined(fingerprint: "b")) == .alert(fingerprint: "a", autoJoined: false))
    }

    @Test func actingOnAnAlertClosesIt() {
        let alert = IslandMode.alert(fingerprint: "a", autoJoined: false)
        #expect(M.reduce(alert, .acknowledged) == .compact)
        #expect(M.reduce(alert, .alertCleared) == .compact)
        #expect(M.reduce(alert, .joined(title: "T", platform: "Zoom")) == .joining(title: "T", platform: "Zoom"))
        #expect(M.reduce(.joining(title: "T", platform: nil), .transientElapsed) == .compact)
    }

    @Test func failedJoinShowsANoticeThenReturns() {
        let alert = IslandMode.alert(fingerprint: "a", autoJoined: false)
        let shown = M.reduce(alert, .joinFailed(notice))
        #expect(shown == .notice(notice, resume: alert))
        #expect(M.reduce(shown, .transientElapsed) == alert)
        #expect(M.reduce(shown, .alertCleared) == .notice(notice, resume: .compact))
        #expect(M.reduce(.peek(pinned: true), .joinFailed(notice)) == .notice(notice, resume: .peek(pinned: true)))
    }

    @Test func joiningFromTheMenuConfirmsOnTheIsland() {
        #expect(M.reduce(.compact, .joined(title: "T", platform: "Zoom")) == .joining(title: "T", platform: "Zoom"))
        #expect(M.reduce(.compact, .joinFailed(notice)) == .notice(notice, resume: .compact))
    }

    @Test func compactIgnoresNoise() {
        for event: IslandEvent in [.hoverExited, .clickedOutside, .alertCleared, .acknowledged, .transientElapsed] {
            #expect(M.reduce(.compact, event) == .compact)
        }
    }

    @Test func transientsHaveDurations() {
        #expect(IslandMode.joining(title: "", platform: nil).transientDuration != nil)
        #expect(IslandMode.notice(notice, resume: .compact).transientDuration != nil)
        #expect(IslandMode.compact.transientDuration == nil)
        #expect(IslandMode.peek(pinned: false).isExpanded)
        #expect(!IslandMode.compact.isExpanded)
    }
}

@Suite struct UrgencyTests {
    func urgency(_ events: [MeetingEvent], dnd: Bool = false) -> Urgency {
        Urgency.make(schedule: MeetingSchedule(events: events, now: referenceNow), dndActive: dnd)
    }

    @Test func glowFollowsTheCountdown() {
        #expect(urgency([]) == .none)
        #expect(urgency([meeting("later", startIn: 45)]) == .none)
        #expect(urgency([meeting("blue", startIn: 15)]) == .upcoming)
        #expect(urgency([meeting("blue", startIn: 5.5)]) == .upcoming)
        #expect(urgency([meeting("orange", startIn: 5)]) == .soon)
        #expect(urgency([meeting("orange", startIn: 1.5)]) == .soon)
        #expect(urgency([meeting("red", startIn: 1)]) == .now)
        #expect(urgency([meeting("red", startIn: 0.1)]) == .now)
    }

    @Test func ongoingMeetingsDoNotGlow() {
        #expect(urgency([meeting("live", startIn: -10, duration: 30)]) == .none)
        #expect(urgency([meeting("live", startIn: -10), meeting("next", startIn: 3)]) == .soon)
    }

    @Test func pausedNeverGlows() {
        #expect(urgency([meeting("red", startIn: 0.5)], dnd: true) == .paused)
        #expect(!Urgency.paused.glows)
        #expect(Urgency.now.glows)
    }
}

@Suite struct IslandPresenterTests {
    func snapshot(
        _ mode: IslandMode, _ events: [MeetingEvent], alert: MeetingEvent? = nil, shownAgo: Double? = nil,
        acknowledged: Set<String> = [], dnd: DNDState = DNDState(), error: String? = nil, synced: Bool = true
    ) -> IslandSnapshot {
        IslandPresenter.snapshot(
            IslandInputs(
                mode: mode, events: events, alertMeeting: alert, alertShownAt: shownAgo.map { referenceNow.addingTimeInterval(-$0) },
                acknowledged: acknowledged, autoJoinDelaySeconds: 5, dnd: dnd, syncError: error, hasSynced: synced,
                now: referenceNow, timeZone: TimeZone(identifier: "UTC")!))
    }

    let standup = meeting("Standup", startIn: 0.7, location: "https://meet.google.com/abc-defg-hij")

    @Test func compactHasNoCard() {
        #expect(snapshot(.compact, [standup]).card == nil)
    }

    @Test func alertCountdownBurnsTheFuse() throws {
        let card = try #require(snapshot(.alert(fingerprint: standup.fingerprint, autoJoined: false), [standup], alert: standup, shownAgo: 2).card)
        #expect(card.isAlert)
        #expect(card.status == "Starts in 0:42")
        #expect(card.statusTone == .brass)
        #expect(card.fuse == 0.4)
        #expect(card.primaryTitle == "Join · 3")
        #expect(card.primary == .join)
        #expect(card.secondary == .dismiss)
        #expect(card.place == "Google Meet")
    }

    @Test func lateAlertIsCoral() throws {
        let late = meeting("Review", startIn: -12, duration: 45, location: "Room 4", details: "https://zoom.us/j/1")
        let card = try #require(snapshot(.alert(fingerprint: late.fingerprint, autoJoined: false), [late], alert: late, shownAgo: 30).card)
        #expect(card.status == "12 min late")
        #expect(card.statusTone == .coral)
        #expect(card.progress != nil)
        #expect(card.place == "Room 4 · Zoom")
        #expect(card.primaryTitle == "Join")
    }

    @Test func autoJoinedAlertOffersRejoinAndDone() throws {
        let card = try #require(snapshot(.alert(fingerprint: standup.fingerprint, autoJoined: true), [standup], alert: standup, shownAgo: 9).card)
        #expect(card.primary == .rejoin)
        #expect(card.secondary == .done)
        #expect(card.fuse == nil)
    }

    @Test func alertWithoutLinkDisablesJoin() throws {
        let chat = meeting("Chat", startIn: 0.5, location: "Kitchen")
        let card = try #require(snapshot(.alert(fingerprint: chat.fingerprint, autoJoined: false), [chat], alert: chat, shownAgo: 1).card)
        #expect(!card.primaryEnabled)
        #expect(card.primary == nil)
        #expect(card.fuse == nil)
        #expect(card.place == "Kitchen")
    }

    @Test func peekShowsTheOngoingMeetingFirst() throws {
        let live = meeting("Live", startIn: -10, duration: 40, url: "https://teams.microsoft.com/l/x")
        let later = meeting("Later", startIn: 120)
        let snap = snapshot(.peek(pinned: false), [later, live])
        let card = try #require(snap.card)
        #expect(card.headline == "Live")
        #expect(card.status == "30m left")
        #expect(card.isLive)
        #expect(card.secondary == .skipAlert)
        #expect(snap.footer.map(\.label) == ["Nearest"])
        #expect(snap.footer.first?.title == "Later")
    }

    @Test func peekOfAnAcknowledgedMeetingHasNoSkip() throws {
        let later = meeting("Later", startIn: 120)
        let card = try #require(snapshot(.peek(pinned: true), [later], acknowledged: [later.fingerprint]).card)
        #expect(card.status == "In 2h")
        #expect(card.secondary == nil)
    }

    @Test func emptyPeekInvitesASync() throws {
        let snap = snapshot(.peek(pinned: true), [])
        let card = try #require(snap.card)
        #expect(card.primary == .syncNow)
        #expect(card.meeting == nil)
        #expect(snap.footerNote == "No more meetings in the next 2 days")
        #expect(snapshot(.peek(pinned: true), [], synced: false).card?.headline == "Waiting for your calendar")
    }

    @Test func pausedPeekOffersResume() throws {
        var dnd = DNDState()
        dnd.start(.oneHour, at: referenceNow.addingTimeInterval(-18 * 60))
        let snap = snapshot(.peek(pinned: true), [standup], dnd: dnd)
        let card = try #require(snap.card)
        #expect(card.status == "Alerts paused · 42m left")
        #expect(card.secondary == .resumeAlerts)
        #expect(snap.urgency == .paused)
        #expect(snap.dndActive)
    }

    @Test func footerListsNearestAndNext() {
        let a = meeting("A", startIn: 30)
        let b = meeting("B", startIn: 90)
        let c = meeting("C", startIn: 200)
        let footer = snapshot(.peek(pinned: true), [c, b, a]).footer
        #expect(footer.map(\.title) == ["A", "B"])
        #expect(footer.first?.relative == "in 30m")
        #expect(footer.first?.time == Formatting.clock(a.start, timeZone: TimeZone(identifier: "UTC")!))
    }

    @Test func syncErrorIsSurfaced() {
        let snap = snapshot(.peek(pinned: true), [meeting("A", startIn: 30)], error: "timed out")
        #expect(snap.syncError == "timed out")
        #expect(snap.footerNote?.contains("sync failed") == true)
    }

    @Test func noticeOverAPeekKeepsTheCard() {
        let snap = snapshot(.notice(.noJoinLink(title: "A"), resume: .peek(pinned: true)), [meeting("A", startIn: 30)])
        #expect(snap.card != nil)
        #expect(snapshot(.joining(title: "A", platform: nil), [meeting("A", startIn: 30)]).card == nil)
    }
}
