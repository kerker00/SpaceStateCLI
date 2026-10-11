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
        #expect(failure.fetchedAt == nil)
        let json = try #require(JSONSerialization.jsonObject(with: Data(Output.json(failure).utf8)) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["error"] as? String == "offline")
        #expect(json["network"] as? String == "error")
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
        #expect(Output.table([snapshot], color: false) == "Space Injected  ● open                <b>&")
        let encoded = try Output.waybar(snapshot)
        #expect(!encoded.contains("\n"))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(decoded["tooltip"] as? String == "&lt;b&gt;&amp; ")
        #expect(decoded["class"] as? String == "open")
        #expect(decoded["text"] as? String == "Space Injected: open")
    }
}
