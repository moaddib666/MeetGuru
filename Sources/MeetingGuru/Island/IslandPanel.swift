import AppKit
import MeetingGuruCore
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keep the island exactly where it's placed; AppKit would otherwise push it below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosts the island on the right screen edge, centred so the open card starts 10% below the top, and turns raw mouse
/// movement into hover / click-outside events. Outside the island the panel ignores
/// the mouse, so the rest of the screen stays clickable.
@MainActor
final class IslandWindowController {
    private let panel: IslandPanel
    private let model: IslandModel
    private var monitors: [Any] = []
    private var hoverTimer: Timer?
    private var inside = false

    static let hoverIntent: TimeInterval = 0.22
    static let exitGrace: TimeInterval = 0.35

    init(model: IslandModel) {
        self.model = model
        panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: Metrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: IslandRootView(model: model))
        model.onResize = { [weak self] in self?.islandDidResize() }
        position()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
        installMonitors()
    }

    func show() { panel.orderFrontRegardless() }

    func position() {
        guard let screen = NSScreen.screens.first else { return }
        let centerY = screen.frame.maxY - (screen.frame.height * Metrics.topFraction).rounded() - Metrics.cardHalfHeight
        let top = centerY + Metrics.panelSize.height / 2
        let origin = NSPoint(
            x: screen.frame.maxX - Metrics.rightInset - Metrics.panelSize.width,
            y: top - Metrics.panelSize.height)
        panel.setFrame(NSRect(origin: origin, size: Metrics.panelSize), display: true)
    }

    /// The island's current footprint in screen coordinates (it is anchored top-right).
    private var islandRect: NSRect {
        let size = model.islandSize
        let frame = panel.frame
        return NSRect(x: frame.maxX - size.width, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            .insetBy(dx: -3, dy: -3)
    }

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: moveMask,
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.trackMouse() }
            })
        {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: moveMask,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.trackMouse() }
                return event
            })
        {
            monitors.append(local)
        }
        if let clicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.clickedElsewhere() }
            })
        {
            monitors.append(clicks)
        }
    }

    func trackMouse() {
        let nowInside = islandRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !nowInside
        guard nowInside != inside else { return }
        inside = nowInside
        Log.debug("Island pointer \(nowInside ? "entered" : "left")")
        hoverTimer?.invalidate()
        let delay = nowInside ? Self.hoverIntent : Self.exitGrace
        let event: IslandEvent = nowInside ? .hoverEntered : .hoverExited
        hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.inside == nowInside else { return }
                self.model.send(event)
                self.trackMouse()
            }
        }
    }

    private func clickedElsewhere() {
        if !islandRect.contains(NSEvent.mouseLocation) { model.send(.clickedOutside) }
    }

    /// Re-evaluates hit-testing after the island changes size under a still cursor.
    func islandDidResize() {
        let nowInside = islandRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !nowInside
        if inside && !nowInside { trackMouse() }
    }

    func teardown() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hoverTimer?.invalidate()
        panel.orderOut(nil)
    }
}
