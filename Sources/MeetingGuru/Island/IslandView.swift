import MeetingGuruCore
import SwiftUI

struct IslandRootView: View {
    let model: IslandModel
    var animated = true

    var body: some View {
        IslandView(model: model, animated: animated)
            .frame(width: Metrics.panelSize.width, height: Metrics.panelSize.height, alignment: .trailing)
    }
}

private enum Phase: Hashable {
    case compact, expanded, transient
}

struct IslandView: View {
    let model: IslandModel
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = CGSize(width: 22, height: 30)
    @State private var morphing = false
    @State private var morphGeneration = 0

    private var snapshot: IslandSnapshot { model.snapshot }

    private var phase: Phase {
        switch snapshot.mode {
        case .compact: .compact
        case .peek, .alert, .invite: snapshot.card == nil ? .compact : .expanded
        case .joining, .replied, .notice: .transient
        }
    }

    private var glowing: Bool { snapshot.urgency.glows && phase == .compact && !morphing }

    private var shoulder: CGFloat { phase == .compact ? 5 : 12 }
    private var radius: CGFloat {
        switch phase {
        case .compact: 6
        case .transient: 20
        case .expanded: 26
        }
    }

    var body: some View {
        let shape = SideIslandShape(shoulder: shoulder, radius: radius)
        sized
            .background {
                ZStack {
                    Color.black
                    if phase == .expanded {
                        CardBackground(index: model.backgroundIndex)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.animation(.easeOut(duration: 0.4).delay(0.22)),
                                    removal: .opacity.animation(.easeIn(duration: 0.1))))
                    }
                }
            }
            .clipShape(shape)
            .background {
                if glowing {
                    IslandGlow(urgency: snapshot.urgency, shape: shape)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.easeIn(duration: 0.45).delay(0.35)),
                                removal: .identity))
                }
            }
            .shadow(color: .black.opacity(phase == .expanded ? 0.5 : 0.25), radius: phase == .expanded ? 20 : 6, x: -4, y: 6)
            .contentShape(shape)
            .onTapGesture { model.send(.clicked) }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Self.liquid, value: phase)
            .animation(.easeInOut(duration: 0.6), value: snapshot.urgency)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var sized: some View {
        let measured =
            content
            .padding(.vertical, shoulder)
            .padding(.trailing, phase == .compact ? 0 : shoulder)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { morph(to: $0) })
        if animated {
            measured.frame(width: shown.width, height: shown.height, alignment: .trailing)
        } else {
            measured
        }
    }

    /// Soft, slightly under-damped spring: the black overshoots a touch and settles like a liquid.
    static let liquid = Animation.spring(response: 0.5, dampingFraction: 0.72)

    /// Liquid morph anchored on the island's vertical centre at the screen edge. Opening,
    /// the black flows left first and then swells up and down around the centre; closing,
    /// it drains vertically first and then retracts into the edge. Content only fades in
    /// once the black has mostly settled, and leaves before it starts to drain.
    private func morph(to target: CGSize) {
        guard target.width > 0, target.height > 0 else { return }
        model.islandSize = target
        if animated, target != shown {
            morphGeneration += 1
            let generation = morphGeneration
            morphing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                if generation == morphGeneration { morphing = false }
            }
        }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { shown = target }
            return
        }
        let flow = Animation.spring(response: 0.42, dampingFraction: 0.74)
        let swell = Animation.spring(response: 0.5, dampingFraction: 0.68)
        if target.height >= shown.height {
            withAnimation(flow) { shown.width = target.width }
            withAnimation(swell.delay(0.05)) { shown.height = target.height }
        } else {
            withAnimation(swell.speed(1.3)) { shown.height = target.height }
            withAnimation(flow.delay(0.08)) { shown.width = target.width }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .compact:
            CompactContent(urgency: snapshot.urgency, hasInvites: snapshot.pendingInvites > 0)
                .transition(
                    .asymmetric(
                        insertion: AnyTransition(.blurReplace).animation(.easeOut(duration: 0.25).delay(0.28)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))))
        case .transient:
            TransientContent(mode: snapshot.mode)
                .transition(
                    .asymmetric(
                        insertion: AnyTransition(.blurReplace).animation(.easeOut(duration: 0.28).delay(0.18)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))))
        case .expanded:
            if let card = snapshot.card {
                CardContentView(model: model, card: card, snapshot: snapshot)
                    .transition(
                        .asymmetric(
                            insertion: AnyTransition(.blurReplace).combined(with: .scale(scale: 0.96, anchor: .trailing))
                                .animation(.easeOut(duration: 0.32).delay(0.2)),
                            removal: AnyTransition(.blurReplace).animation(.easeIn(duration: 0.1))))
            }
        }
    }
}

// MARK: - Compact

struct Mascot: View {
    var size: CGFloat
    var opacity: Double = 1
    var color: Color = .white

    var body: some View {
        Image(nsImage: Assets.mascot)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(color.opacity(opacity))
            .accessibilityHidden(true)
    }
}

/// The collapsed island: only the mascot, tinted by how close the next meeting is.
private struct CompactContent: View {
    let urgency: Urgency
    let hasInvites: Bool

    var body: some View {
        Mascot(size: 10.8, opacity: urgency == .paused ? 0.35 : 1, color: urgency.glows ? Palette.urgency(urgency) : .white)
            .shadow(color: urgency.glows ? Palette.urgency(urgency).opacity(0.8) : .clear, radius: 3)
            .overlay(alignment: .topLeading) {
                if hasInvites {
                    Circle().fill(Palette.urgencyBlue).frame(width: 4, height: 4).offset(x: -3, y: -2)
                }
            }
            .padding(.vertical, 4.5)
            .padding(.leading, 6.5)
            .padding(.trailing, 4.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let status =
            switch urgency {
            case .none: "MeetingGuru"
            case .upcoming: "Next meeting within 15 minutes"
            case .soon: "Next meeting within 5 minutes"
            case .now: "Next meeting starts within a minute"
            case .paused: "Alerts paused"
            }
        return hasInvites ? "\(status), invitations waiting" : status
    }
}

/// A breathing halo behind the island; it breathes faster as the meeting gets closer.
private struct IslandGlow: View {
    let urgency: Urgency
    let shape: SideIslandShape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var period: Double {
        switch urgency {
        case .now: 0.7
        case .soon: 1.4
        default: 2.4
        }
    }

    var body: some View {
        let color = Palette.urgency(urgency)
        if reduceMotion {
            halo(color, strength: 0.75)
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate / period * 2 * .pi
                halo(color, strength: 0.72 + 0.28 * sin(phase))
            }
        }
    }

    private func halo(_ color: Color, strength: Double) -> some View {
        ZStack {
            shape.fill(color).blur(radius: 16).opacity(0.9)
            shape.fill(color).blur(radius: 9).opacity(0.45)
        }
        .opacity(strength)
        .allowsHitTesting(false)
    }
}

struct LiveDot: View {
    var size: CGFloat
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Palette.coral)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(Palette.coral.opacity(0.45))
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 1)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

// MARK: - Transient

private struct TransientContent: View {
    let mode: IslandMode

    var body: some View {
        HStack(spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(width: 290)
    }

    @ViewBuilder
    private var icon: some View {
        switch mode {
        case .notice(let notice, _):
            Image(systemName: notice == .replyFailed(title: notice.title) ? "exclamationmark.bubble.fill" : "link.badge.plus")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.coral)
                .frame(width: 28, height: 28)
        case .replied(_, let response):
            Image(systemName: Self.symbol(for: response))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(response == .declined ? Palette.dim : Palette.brass)
                .frame(width: 28, height: 28)
        default:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.brass)
                .frame(width: 28, height: 28)
        }
    }

    static func symbol(for response: InviteResponse) -> String {
        switch response {
        case .accepted: "checkmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .declined: "xmark.circle.fill"
        }
    }

    private var headline: String {
        switch mode {
        case .joining(_, let platform): "Opening \(platform ?? "meeting")"
        case .replied(_, let response): response.confirmation
        case .notice(let notice, _): notice.message
        default: ""
        }
    }

    private var subtitle: String {
        switch mode {
        case .joining(let title, _), .replied(let title, _): title
        case .notice(let notice, _): notice.title
        default: ""
        }
    }
}

// MARK: - Card

private struct CardBackground: View {
    let index: Int

    var body: some View {
        ZStack {
            if let image = Assets.background(index) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black, location: 0.5)],
                            startPoint: .leading, endPoint: .trailing)
                    }
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.10), location: 0),
                    .init(color: .black.opacity(0.28), location: 0.5),
                    .init(color: .black.opacity(0.82), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

private struct CardContentView: View {
    let model: IslandModel
    let card: CardContent
    let snapshot: IslandSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(card.headline)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)
            if let place = card.place {
                Label {
                    Text(place).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: card.meeting?.meetingURL != nil ? "video.fill" : "mappin")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.dim)
                .padding(.top, 5)
            }
            if let invite = card.invite, let from = inviteDetail(invite) {
                Label {
                    Text(from).lineLimit(1).truncationMode(.tail)
                } icon: {
                    Image(systemName: "person.fill").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.dim)
                .padding(.top, 4)
            }
            if let progress = card.progress {
                ProgressLine(value: progress, tint: card.isAlert ? Palette.coral : Palette.ink.opacity(0.85))
                    .padding(.top, 13)
            }
            Group {
                if let invite = card.invite {
                    InviteActions(model: model, card: card, invite: invite)
                } else {
                    actions
                }
            }
            .padding(.top, 15)
            footer.padding(.top, 14)
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 14)
        .frame(width: Metrics.cardWidth - 24, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Mascot(size: 15, opacity: 0.92)
            StatusChip(text: card.status, tone: card.statusTone, live: card.isLive && card.statusTone != .brass)
            Spacer(minLength: 8)
            if let range = card.timeRange {
                Text(range)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.dim)
            }
        }
        .frame(height: 22)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            FuseButton(
                title: card.primaryTitle,
                symbol: symbol(for: card.primary),
                fuse: card.fuse,
                enabled: card.primaryEnabled
            ) {
                if let action = card.primary { model.primary(action, card.meeting) }
            }
            if let secondary = card.secondary, let title = card.secondaryTitle {
                QuietButton(title: title) { model.secondary(secondary, card.meeting) }
                    .frame(width: 118)
            }
        }
    }

    private func inviteDetail(_ invite: InviteCard) -> String? {
        let parts = [invite.from.map { "From \($0)" }, invite.repeats ? "Repeats" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func symbol(for action: PrimaryAction?) -> String {
        switch action {
        case .join: "video.fill"
        case .rejoin: "arrow.uturn.forward"
        case .syncNow: "arrow.triangle.2.circlepath"
        case nil: "video.slash.fill"
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if !snapshot.footer.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    ForEach(snapshot.footer, id: \.label) { entry in
                        FooterItem(entry: entry)
                    }
                }
            }
            if let note = snapshot.footerNote {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(snapshot.syncError != nil ? Palette.coral.opacity(0.9) : Palette.faint)
                    .help(snapshot.syncError ?? "")
            }
        }
    }
}

/// Accept / Maybe / Decline, and "Later" to answer from the menu instead.
private struct InviteActions: View {
    let model: IslandModel
    let card: CardContent
    let invite: InviteCard

    var body: some View {
        HStack(spacing: 8) {
            FuseButton(
                title: title(.accepted), symbol: "checkmark", fuse: nil, enabled: invite.sending == nil
            ) { model.respond(invite.inviteID, .accepted) }
            QuietButton(title: title(.tentative)) { model.respond(invite.inviteID, .tentative) }
                .frame(width: 70)
                .disabled(invite.sending != nil)
            QuietButton(title: title(.declined)) { model.respond(invite.inviteID, .declined) }
                .frame(width: 70)
                .disabled(invite.sending != nil)
            QuietButton(title: card.secondaryTitle ?? "Later") { model.secondary(.later, card.meeting) }
                .frame(width: 54)
                .disabled(invite.sending != nil)
        }
        .opacity(invite.sending == nil ? 1 : 0.6)
    }

    private func title(_ response: InviteResponse) -> String {
        invite.sending == response ? "Sending…" : response.label
    }
}

private struct FooterItem: View {
    let entry: FooterEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(entry.label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Palette.faint)
            Text(entry.time)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.dim)
            Text(entry.title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(entry.relative.map { "\(entry.title) — \($0)" } ?? entry.title)
    }
}

private struct StatusChip: View {
    let text: String
    let tone: Tone
    let live: Bool

    var body: some View {
        HStack(spacing: 5) {
            if live {
                LiveDot(size: 5)
            } else if tone == .brass {
                Image(systemName: "clock.fill").font(.system(size: 9, weight: .bold))
            } else if tone == .coral {
                Image(systemName: "exclamationmark").font(.system(size: 9, weight: .heavy))
            } else if tone == .azure {
                Image(systemName: "envelope.fill").font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(countsDown: true))
        }
        .foregroundStyle(Palette.tone(tone))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Palette.tone(tone).opacity(tone == .neutral ? 0.10 : 0.15)))
    }
}

private struct ProgressLine: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(tint).frame(width: max(3, proxy.size.width * value))
            }
        }
        .frame(height: 3)
        .animation(.easeInOut(duration: 0.6), value: value)
        .accessibilityValue("\(Int(value * 100)) percent elapsed")
    }
}

// MARK: - Buttons

/// Primary action. While auto-join is armed a brass "fuse" burns across it.
struct FuseButton: View {
    let title: String
    let symbol: String
    let fuse: Double?
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                Capsule().fill(enabled ? Color(white: hovering ? 1 : 0.93) : Color.white.opacity(0.08))
                if let fuse, enabled {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Palette.brass)
                            .frame(width: proxy.size.width * fuse)
                            .animation(.linear(duration: 1), value: fuse)
                    }
                    .clipShape(Capsule())
                }
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                }
                .foregroundStyle(enabled ? Color.black : Palette.faint)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct QuietButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.17 : 0.10)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
