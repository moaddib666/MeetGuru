import Foundation

public enum MeetingLinks {
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"'\\]+"#, options: [.caseInsensitive])
    private static let platformHost = try! NSRegularExpression(
        pattern:
            #"(^|\.)(zoom\.us|zoomgov\.com|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|gotomeeting\.com|goto\.com|whereby\.com|meet\.jit\.si|bluejeans\.com|chime\.aws|skype\.com|meet\.lync\.com|around\.co|discord\.gg|slack\.com)$"#,
        options: [.caseInsensitive])
    private static let selfHostedHost = try! NSRegularExpression(
        pattern: #"^(meet|meeting|jitsi|video|conf|conference)\."#, options: [.caseInsensitive])
    private static let trailingPunctuation = Set(".,;:!?)]}>'\"")

    public static func findURLs(in text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return urlPattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { unwrapSafelink(clean(String(text[$0]))) }
        }
    }

    /// A known conferencing platform wins; otherwise the first URL found.
    public static func bestJoinLink(from sources: [String?]) -> String? {
        let candidates = sources.flatMap { findURLs(in: $0) }
        return candidates.first(where: isMeetingPlatform) ?? candidates.first
    }

    public static func isMeetingPlatform(_ url: String) -> Bool {
        guard let host = host(of: url) else { return false }
        return matches(platformHost, host) || matches(selfHostedHost, host)
    }

    public static func host(of url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        var authority = url[schemeEnd.upperBound...]
        if let end = authority.firstIndex(where: { "/?#".contains($0) }) {
            authority = authority[..<end]
        }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        if let colon = authority.firstIndex(of: ":") {
            authority = authority[..<colon]
        }
        let host = authority.lowercased()
        return host.isEmpty ? nil : host
    }

    public static func platformName(for url: String?) -> String? {
        guard let url, let host = host(of: url) else { return nil }
        let known: [(String, String)] = [
            ("zoom.us", "Zoom"), ("zoomgov.com", "Zoom"), ("meet.google.com", "Google Meet"),
            ("teams.microsoft.com", "Microsoft Teams"), ("teams.live.com", "Microsoft Teams"),
            ("webex.com", "Webex"), ("gotomeeting.com", "GoTo Meeting"), ("goto.com", "GoTo Meeting"),
            ("whereby.com", "Whereby"), ("meet.jit.si", "Jitsi"), ("bluejeans.com", "BlueJeans"),
            ("chime.aws", "Amazon Chime"), ("skype.com", "Skype"), ("slack.com", "Slack"),
            ("discord.gg", "Discord"), ("around.co", "Around"),
        ]
        for (suffix, name) in known where host == suffix || host.hasSuffix("." + suffix) {
            return name
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public static func isOpenable(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    private static func clean(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = url.last, trailingPunctuation.contains(last) {
            url.removeLast()
        }
        return url.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func unwrapSafelink(_ url: String) -> String {
        guard let host = host(of: url), host.hasSuffix("safelinks.protection.outlook.com"),
            let queryStart = url.firstIndex(of: "?")
        else { return url }
        var query = url[url.index(after: queryStart)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "url" else { continue }
            let value = parts[1].replacingOccurrences(of: "+", with: " ")
            if let decoded = value.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        return url
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
