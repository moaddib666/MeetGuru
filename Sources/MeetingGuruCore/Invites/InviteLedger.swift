import Foundation

/// Invites the user has already seen on the island (answered or put off with "Later"),
/// so each one pops up once rather than on every sync or launch.
public final class InviteLedger {
    public let fileURL: URL?
    public private(set) var seen: Set<String>

    public static var defaultURL: URL { ConfigStore.defaultDirectory.appendingPathComponent("invites.json") }

    /// A nil `fileURL` keeps the ledger in memory only.
    public init(fileURL: URL? = InviteLedger.defaultURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        {
            seen = Set(stored.seen)
        } else {
            seen = []
        }
    }

    public func contains(_ id: String) -> Bool { seen.contains(id) }

    public func markSeen(_ id: String) {
        guard seen.insert(id).inserted else { return }
        save()
    }

    /// Forgets invites that are no longer pending, keeping the file small.
    public func retain(only pending: Set<String>) {
        let kept = seen.intersection(pending)
        guard kept != seen else { return }
        seen = kept
        save()
    }

    private struct Stored: Codable {
        var seen: [String]
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Stored(seen: seen.sorted()))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("Could not save seen invites: \(error.localizedDescription)")
        }
    }
}
