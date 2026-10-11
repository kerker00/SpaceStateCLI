import Foundation
import SpaceAPI

/// Everything `info` shows about a space: its snapshot plus location, contacts, feeds and links.
/// Empty parts are left out, both in text and in JSON.
public struct Profile: Encodable, Sendable {
    struct Location: Encodable, Sendable {
        var address: String?
        var latitude: Double?
        var longitude: Double?
        var timezone: String?
        var country: String?
        var hint: String?
    }
    struct Icons: Encodable, Sendable {
        var open: URL
        var closed: URL
    }
    struct Contact: Encodable, Sendable {
        var email, phone, matrix, mastodon, irc, xmpp, mumble, sip, mailingList, issueMail, gopher: String?
    }
    struct Keymaster: Encodable, Sendable {
        var name, ircNick, phone, email, xmpp, mastodon, matrix: String?
    }
    struct Feed: Encodable, Sendable {
        var kind: String
        var url: URL
        var type: String?
    }
    struct Link: Encodable, Sendable {
        var name: String
        var description: String?
        var url: URL
    }
    struct LinkedSpace: Encodable, Sendable {
        var endpoint: URL?
        var website: URL?
    }

    public let snapshot: Snapshot
    var website: URL?
    var logo: URL?
    var location: Location?
    var icons: Icons?
    var contact: Contact?
    var keymasters: [Keymaster]?
    var feeds: [Feed]?
    var links: [Link]?
    var projects: [URL]?
    var linkedSpaces: [LinkedSpace]?
    var apiCompatibility: [String]?

    private enum CodingKeys: String, CodingKey {
        case website, logo, location, icons, contact, keymasters, feeds, links, projects, linkedSpaces, apiCompatibility
    }

    public init(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        guard let info = snapshot.info else { return }
        website = info.website
        logo = info.logo
        location = info.location.map {
            Location(address: $0.address, latitude: $0.latitude, longitude: $0.longitude, timezone: $0.timezone,
                     country: $0.countryCode, hint: $0.hint)
        }
        icons = info.state?.icon.map { Icons(open: $0.open, closed: $0.closed) }
        let c = info.contact
        let contact = Contact(email: c.email, phone: c.phone, matrix: c.matrix, mastodon: c.mastodon, irc: c.irc, xmpp: c.xmpp,
                              mumble: c.mumble, sip: c.sip, mailingList: c.mailingList, issueMail: c.issueMail, gopher: c.gopher)
        self.contact = Self.lines(contact).isEmpty ? nil : contact
        keymasters = Self.nonEmpty(c.keymasters.map {
            Keymaster(name: $0.name, ircNick: $0.ircNick, phone: $0.phone, email: $0.email, xmpp: $0.xmpp, mastodon: $0.mastodon, matrix: $0.matrix)
        })
        let f = info.feeds
        feeds = Self.nonEmpty([("calendar", f.calendar), ("blog", f.blog), ("wiki", f.wiki), ("flickr", f.flickr)].compactMap { kind, feed in
            feed.map { Feed(kind: kind, url: $0.url, type: $0.type) }
        })
        links = Self.nonEmpty(info.links.map { Link(name: $0.name, description: $0.description, url: $0.url) })
        projects = Self.nonEmpty(info.projects)
        linkedSpaces = Self.nonEmpty(info.linkedSpaces.map { LinkedSpace(endpoint: $0.endpoint, website: $0.website) })
        apiCompatibility = Self.nonEmpty(info.apiCompatibility)
    }

    /// The snapshot's fields first, then the details, in one flat object.
    public func encode(to encoder: any Encoder) throws {
        try snapshot.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(website, forKey: .website)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(icons, forKey: .icons)
        try container.encodeIfPresent(contact, forKey: .contact)
        try container.encodeIfPresent(keymasters, forKey: .keymasters)
        try container.encodeIfPresent(feeds, forKey: .feeds)
        try container.encodeIfPresent(links, forKey: .links)
        try container.encodeIfPresent(projects, forKey: .projects)
        try container.encodeIfPresent(linkedSpaces, forKey: .linkedSpaces)
        try container.encodeIfPresent(apiCompatibility, forKey: .apiCompatibility)
    }

    /// The status line, then one labelled block per part the space publishes.
    public func text(color: Bool, now: Date = Date()) -> String {
        var lines = [Output.table([snapshot], color: color, now: now)]
        func add(_ label: String, _ values: [String]) {
            for (index, value) in values.enumerated() {
                let title = index == 0 ? label : ""
                let padded = title + String(repeating: " ", count: 10 - title.count)
                lines.append("  " + (color ? "\u{1B}[2m\(padded)\u{1B}[0m" : padded) + "  " + Output.plain(value))
            }
        }
        add("Website", [website?.absoluteString].compactMap { $0 })
        if let location {
            let place = [location.address, location.country.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            add("Address", place.isEmpty ? [] : [place])
            add("Access", [location.hint].compactMap { $0 })
        }
        add("Contact", contact.map(Self.lines) ?? [])
        // Names only; how to reach each keymaster is in the JSON.
        let names = (keymasters ?? []).compactMap { $0.name ?? $0.ircNick }
        add("Keymasters", names.isEmpty ? [] : [names.joined(separator: ", ")])
        add("Feeds", Self.pairs((feeds ?? []).map { ($0.kind.capitalized, $0.url.absoluteString) }))
        add("Links", Self.pairs((links ?? []).map { ($0.name, $0.url.absoluteString) }))
        add("Projects", (projects ?? []).map(\.absoluteString))
        add("Linked", (linkedSpaces ?? []).compactMap { ($0.website ?? $0.endpoint)?.absoluteString })
        add("Endpoint", [snapshot.endpoint.absoluteString])
        return lines.joined(separator: "\n")
    }

    private static func lines(_ contact: Contact) -> [String] {
        pairs([("Email", contact.email), ("Phone", contact.phone), ("Matrix", contact.matrix), ("Mastodon", contact.mastodon),
               ("IRC", contact.irc), ("XMPP", contact.xmpp), ("Mumble", contact.mumble), ("SIP", contact.sip),
               ("List", contact.mailingList), ("Issues", contact.issueMail), ("Gopher", contact.gopher)]
            .compactMap { label, value in value.map { (label, $0) } })
    }

    /// Label and value per line, the values aligned after the longest label.
    private static func pairs(_ items: [(String, String)]) -> [String] {
        let labels = items.map { Output.plain($0.0) }
        let width = labels.map(\.count).max() ?? 0
        return zip(labels, items).map { label, item in
            label + String(repeating: " ", count: width - label.count) + "  " + item.1
        }
    }

    private static func nonEmpty<T>(_ values: [T]) -> [T]? {
        values.isEmpty ? nil : values
    }
}
