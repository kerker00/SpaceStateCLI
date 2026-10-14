import Foundation
import Testing
import SpaceAPI
@testable import CLIKit

struct CLIKitTests {
    private func target(_ name: String, _ host: String) -> Target {
        Target(endpoint: URL(string: "https://\(host)/spaceapi.json")!, name: name)
    }

    @Test func resolvesNamesExactlyThenByPrefixThenBySubstring() {
        let spaces = [target("Mainframe", "status.mainframe.io"), target("Chaosdorf", "chaosdorf.de"),
                      target("Chaospott", "chaospott.de"), target("Bitlair", "bitlair.nl"), target("Bit", "bit.example")]
        #expect(Resolver.resolve("mainframe", in: spaces) == .found(spaces[0]))
        #expect(Resolver.resolve("  MAIN ", in: spaces) == .found(spaces[0]))
        #expect(Resolver.resolve("bit", in: spaces) == .found(spaces[4]))
        #expect(Resolver.resolve("chaos", in: spaces) == .ambiguous([spaces[1], spaces[2]]))
        #expect(Resolver.resolve("pott", in: spaces) == .found(spaces[2]))
        #expect(Resolver.resolve("bitlair.nl", in: spaces) == .found(spaces[3]))
        #expect(Resolver.resolve("nowhere", in: spaces) == .notFound)
        #expect(Resolver.resolve("", in: spaces) == .notFound)
    }

    @Test func validatesURLsAndIntervals() throws {
        #expect(try Resolver.webURL("http://localhost/status").host == "localhost")
        for url in ["file:///tmp/test", "https://user:secret@space.test", "mainframe"] {
            #expect(throws: UsageError.self) { try Resolver.webURL(url) }
        }
        #expect(try pollInterval("90") == 90)
        #expect(try pollInterval("30s") == 30)
        #expect(try pollInterval("5m") == 300)
        #expect(try pollInterval("1H") == 3600)
        for text in ["nan", "0", "4s", "25h", "m", "5 minutes"] {
            #expect(throws: UsageError.self) { try pollInterval(text) }
        }
    }

    @Test func savedSpacesKeepHandEditedLines() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "spacestate-\(UUID())/spaces")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let saved = SavedSpaces(file: file)
        #expect(try saved.load().isEmpty)
        let mainframe = target("Mainframe", "status.mainframe.io")
        let bitlair = target("Bitlair", "bitlair.nl")
        #expect(try saved.add([mainframe, bitlair, mainframe]) == [mainframe, bitlair])
        #expect(try saved.add([mainframe]).isEmpty)
        try Data((try String(contentsOf: file, encoding: .utf8) + "# mine\nhttps://other.test/api\n").utf8).write(to: file)
        try saved.remove([mainframe])
        #expect(try saved.load() == [bitlair, Target(endpoint: URL(string: "https://other.test/api")!, name: nil)])
        #expect(try String(contentsOf: file, encoding: .utf8).contains("# mine\n"))
        try Data("not a url\n".utf8).write(to: file)
        #expect(throws: UsageError.self) { try saved.load() }
    }

    @Test func unknownStateAndNetworkFailureRemainDistinct() throws {
        let space = target("Space", "space.test")
        let success = Snapshot(space, info: SpaceInfo(name: "Space"))
        #expect(success.status == .unknown)
        #expect(!success.failed)
        let failure = Snapshot(space, info: nil, error: "offline")
        #expect(failure.status == .unknown)
        #expect(failure.failed)
        #expect(failure.name == "Space")
        let json = try #require(JSONSerialization.jsonObject(with: Data(Output.json(failure).utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["endpoint", "name", "status", "reportedStatus", "attemptedAt", "freshness", "error"])
        #expect(json["error"] as? String == "offline")
        #expect(json["endpoint"] as? String == "https://space.test/spaceapi.json")
    }

    @Test func directoryEntriesUseTheAggregatorsTime() {
        let seen = Date(timeIntervalSince1970: 1_000)
        let entry = DirectoryEntry(endpoint: URL(string: "https://a.test/api")!, info: SpaceInfo(name: "A"), lastSeen: seen)
        #expect(Snapshot(entry).checkedAt == seen)
    }

    @Test func profileShowsOnlyWhatTheSpacePublishes() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var info = SpaceInfo(
            name: "Lab", website: URL(string: "https://lab.test"),
            location: .init(address: "Street 1", latitude: nil, longitude: nil, timezone: nil, countryCode: "DE", hint: "Ring twice"),
            state: .init(open: true, lastChange: nil, message: nil, triggerPerson: nil),
            contact: .init(email: "hi@lab.test", mastodon: "@lab@social.test", keymasters: [.init(name: "Ada", email: "a@lab.test")]),
            links: [.init(name: "Wiki", url: URL(string: "https://wiki.lab.test")!)])
        info.feeds.calendar = .init(url: URL(string: "https://lab.test/cal.ics")!, type: "ical")
        let profile = Profile(Snapshot(target("Lab", "lab.test"), info: info, now: now))
        #expect(profile.text(color: false, now: now) == """
            Lab  ● open
              Website     https://lab.test
              Address     Street 1 (DE)
              Access      Ring twice
              Contact     Email     hi@lab.test
                          Mastodon  @lab@social.test
              Keymasters  Ada
              Feeds       Calendar  https://lab.test/cal.ics
              Links       Wiki  https://wiki.lab.test
              Endpoint    https://lab.test/spaceapi.json
            """)
        let json = try #require(JSONSerialization.jsonObject(with: Data(Output.json(profile).utf8)) as? [String: Any])
        #expect(json["name"] as? String == "Lab")
        #expect((json["location"] as? [String: Any])?["country"] as? String == "DE")
        #expect((json["keymasters"] as? [[String: Any]])?.first?["email"] as? String == "a@lab.test")
        #expect((json["feeds"] as? [[String: Any]])?.first?["kind"] as? String == "calendar")
        #expect(json["projects"] == nil)
        #expect(json["icons"] == nil)

        let unreachable = Profile(Snapshot(target("Gone", "gone.test"), info: nil, error: "timeout", now: now))
        #expect(unreachable.text(color: false, now: now) == """
            Gone  ? unknown              unreachable: timeout
              Endpoint    https://gone.test/spaceapi.json
            """)
    }

    @Test func tableAlignsAndQuietCodeSummarises() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let open = Snapshot(target("Mainframe", "a.test"), info: SpaceInfo(
            name: "Mainframe", state: .init(open: true, lastChange: now.addingTimeInterval(-7200), message: "Hi", triggerPerson: nil)), now: now)
        let closed = Snapshot(target("AFRA", "b.test"), info: SpaceInfo(
            name: "AFRA", state: .init(open: false, lastChange: nil, message: nil, triggerPerson: nil)), now: now)
        let failed = Snapshot(target("Gone", "c.test"), info: nil, error: "timeout", now: now)
        #expect(Output.table([open, closed, failed], color: false, now: now) == """
            Mainframe  ● open     for 2 h     Hi
            AFRA       ○ closed
            Gone       ? unknown              unreachable: timeout
            """)
        #expect(Output.exitCode([open]) == 0)
        #expect(Output.exitCode([open, closed]) == 1)
        #expect(Output.exitCode([closed, failed]) == 2)
        #expect(Output.elapsed(since: now.addingTimeInterval(-30), now: now) == "<1 min")
        #expect(Output.elapsed(since: now.addingTimeInterval(-3 * 86400), now: now) == "3 days")
    }

    @Test func outputEscapesMarkupAndTerminalControls() throws {
        let info = SpaceInfo(name: "Space\nInjected", state: .init(open: true, lastChange: nil, message: "<b>&\n", triggerPerson: nil))
        let snapshot = Snapshot(target("Space", "space.test"), info: info)
        #expect(Output.table([snapshot], color: false) == "Space Injected  ● open" + String(repeating: " ", count: 17) + "<b>&")
        let encoded = try Output.waybar(snapshot)
        #expect(!encoded.contains("\n"))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(decoded["tooltip"] as? String == "&lt;b&gt;&amp; ")
        #expect(decoded["class"] as? String == "open")
        #expect(decoded["text"] as? String == "Space Injected: open")
    }
}
