import Foundation

/// Minimal namespace-aware XML tree for WebDAV multistatus responses.
public final class XMLNode: @unchecked Sendable {
    public let namespace: String
    public let name: String
    public var text = ""
    public var attributes: [String: String] = [:]
    public var children: [XMLNode] = []

    init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }

    public func child(_ name: String, _ namespace: String = DAV.dav) -> XMLNode? {
        children.first { $0.name == name && $0.namespace == namespace }
    }

    public func all(_ name: String, _ namespace: String = DAV.dav) -> [XMLNode] {
        children.filter { $0.name == name && $0.namespace == namespace }
    }

    public func descendants(_ name: String, _ namespace: String = DAV.dav) -> [XMLNode] {
        children.flatMap { ($0.name == name && $0.namespace == namespace ? [$0] : []) + $0.descendants(name, namespace) }
    }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public static func parse(_ data: Data) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw CalDAVError.badResponse("Invalid XML from server: \(parser.parserError?.localizedDescription ?? "empty body")")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let node = XMLNode(namespace: namespaceURI ?? "", name: elementName)
            node.attributes = attributeDict
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}

public enum DAV {
    public static let dav = "DAV:"
    public static let caldav = "urn:ietf:params:xml:ns:caldav"

    /// One `<response>` of a multistatus: its href and the properties that came back 200.
    public struct Response {
        public var href: String
        public var properties: [XMLNode]

        public func property(_ name: String, _ namespace: String = DAV.dav) -> XMLNode? {
            properties.first { $0.name == name && $0.namespace == namespace }
        }
    }

    public static func responses(in root: XMLNode) -> [Response] {
        root.all("response").map { response in
            let href = response.child("href")?.trimmedText ?? ""
            let props = response.all("propstat").filter { propstat in
                let status = propstat.child("status")?.trimmedText ?? "200"
                return status.contains(" 200") || status == "200"
            }.flatMap { $0.child("prop")?.children ?? [] }
            return Response(href: href, properties: props)
        }
    }

    static func propfind(_ props: [(String, String)]) -> Data {
        let body = props.map { name, namespace in namespace == caldav ? "<C:\(name)/>" : "<D:\(name)/>" }.joined()
        return Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop>\(body)</D:prop></D:propfind>
            """.utf8)
    }

    static func calendarQuery(start: Date, end: Date, expand: Bool) -> Data {
        let s = utcStamp(start)
        let e = utcStamp(end)
        let data = expand ? "<C:calendar-data><C:expand start=\"\(s)\" end=\"\(e)\"/></C:calendar-data>" : "<C:calendar-data/>"
        return Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">\
            <D:prop><D:getetag/>\(data)</D:prop>\
            <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">\
            <C:time-range start="\(s)" end="\(e)"/></C:comp-filter></C:comp-filter></C:filter>\
            </C:calendar-query>
            """.utf8)
    }

    static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
