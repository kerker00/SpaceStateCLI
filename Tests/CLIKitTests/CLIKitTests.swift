import Foundation
import Testing
import SpaceAPI
@testable import CLIKit

struct CLIKitTests {
    @Test func validatesCommandsAndOptions() throws {
        let options = try Options(["status", "--space", "http://localhost/status", "--format", "json"])
        #expect(options.endpoint?.host == "localhost")
        #expect(options.format == "json")
        for args in [["status"], ["search"], ["watch", "--space", "file:///tmp/test"],
                     ["watch", "--space", "https://space.test", "--interval", "nan"],
                     ["watch", "--space", "https://space.test", "--interval", "0"],
                     ["status", "--space", "https://user:secret@space.test"],
                     ["status", "--space", "https://space.test", "--format", "ndjson"]] {
            #expect(throws: UsageError.self) { try Options(args) }
        }
    }
    @Test func unknownStateAndNetworkFailureRemainDistinct() throws {
        let endpoint = URL(string: "https://space.test")!
        let success = Snapshot(endpoint: endpoint, info: SpaceInfo(name: "Space"))
        #expect(success.status == .unknown)
        #expect(success.network == "ok")
        let failure = Snapshot(endpoint: endpoint, info: nil, error: "offline")
        #expect(failure.status == .unknown)
        #expect(failure.network == "error")
        #expect(failure.fetchedAt == nil)
        let json = try #require(JSONSerialization.jsonObject(with: Data(Output.json(failure).utf8)) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["error"] as? String == "offline")
    }
    @Test func outputEscapesMarkupAndTerminalControls() throws {
        let info = SpaceInfo(name: "Space\nInjected", state: .init(open: true, lastChange: nil, message: "<b>&\n", triggerPerson: nil))
        let snapshot = Snapshot(endpoint: URL(string: "https://space.test")!, info: info)
        #expect(try Output.snapshot(snapshot, format: "text") == "Space Injected: open — <b>& ")
        let encoded = try Output.snapshot(snapshot, format: "waybar-json")
        #expect(!encoded.contains("\n"))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(decoded["tooltip"] as? String == "&lt;b&gt;&amp; ")
        #expect(decoded["class"] as? String == "open")
    }
}
