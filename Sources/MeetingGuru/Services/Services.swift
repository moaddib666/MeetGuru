import AVFoundation
import AppKit
import MeetingGuruCore

enum Assets {
    /// Bundled resources in the .app, or the package's Resources folder during `swift run`.
    static let root: URL = {
        if let bundled = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("mascot.png").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
    }()

    static let backgroundCount = 7

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    static let mascot: NSImage = {
        let image = NSImage(contentsOf: url("mascot.png")) ?? NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }()

    private static var backgroundCache: [Int: NSImage] = [:]

    static func background(_ index: Int) -> NSImage? {
        let key = ((index % backgroundCount) + backgroundCount) % backgroundCount
        if let cached = backgroundCache[key] { return cached }
        let image = NSImage(contentsOf: url("Backgrounds/background_\(key).jpg"))
        backgroundCache[key] = image
        return image
    }
}

final class SoundPlayer {
    private var player: AVAudioPlayer?

    func playAlert(volume: Double) {
        do {
            player?.stop()
            let player = try AVAudioPlayer(contentsOf: Assets.url("alert.mp3"))
            player.volume = Float(max(0, min(1, volume)))
            player.play()
            self.player = player
        } catch {
            Log.error("Error playing alert sound: \(error)")
        }
    }

    /// A softer chime for new invitations than the meeting alert.
    func playInvite(volume: Double) {
        guard let chime = NSSound(named: "Glass")?.copy() as? NSSound else { return }
        chime.volume = Float(max(0, min(1, volume)))
        chime.play()
    }

    func stop() { player?.stop() }
}

enum Browser {
    static func open(_ link: String) -> Bool {
        guard MeetingLinks.isOpenable(link), let url = URL(string: link) else {
            Log.error("Invalid URL format: \(link)")
            return false
        }
        let opened = NSWorkspace.shared.open(url)
        if opened { Log.info("Opened URL: \(link)") } else { Log.error("Could not open URL: \(link)") }
        return opened
    }
}

enum TrayIcon {
    private static var cache: [String: NSImage] = [:]

    /// The mascot tinted with a status colour, sized for the menu bar.
    static func image(hex: String) -> NSImage {
        let key = hex.lowercased()
        if let cached = cache[key] { return cached }
        let color = NSColor(hex: hex) ?? .white
        let source = Assets.mascot
        let height: CGFloat = 18
        let size = NSSize(width: height * source.size.width / max(source.size.height, 1), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }

    static func clearCache() { cache.removeAll() }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
