import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpaceAPI
import Synchronization
import Testing
@testable import CLIKit

struct EndpointBoundaryTests {
    private static let source = URL(string: "https://directory.example/api")!
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "spacestate-c08-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "data")
    }

    private func directoryData() throws -> Data {
        let urls = ["http://localhost/status", "https://space.example/api", "file:///tmp/status",
                    "https://user:secret@space.example/api", "https://space.example/api\n",
                    "https://space.example/%0A", "https://space.example:65536/api"]
        return try JSONSerialization.data(withJSONObject: urls.map { ["url": $0, "data": ["space": $0]] })
    }

    private func expectValid(_ entries: [DirectoryEntry]) {
        #expect(Set(entries.map(\.endpoint.absoluteString)) == ["http://localhost/status", "https://space.example/api"])
    }

    @Test func manualURLsUseKitContractWithoutChangingIdentity() throws {
        for string in ["http://localhost/status", "https://[::1]:443/api", "https://space.example/a%20b?x=a+b",
                       "https://space.example/%250A"] {
            #expect(try Resolver.webURL(string) == SpaceEndpoint.parse(string))
        }
    }

    @Test func invalidManualErrorsDoNotEchoCredentialsOrControls() {
        for string in ["file:///tmp/status", "https://user:secret@space.example/api", "https://space.example/api\n",
                       "https://space.example/\u{1b}", "https://space.example/%0A", "https://space.example:/api",
                       "https://space.example:65536/api", "https://space.example:9999999999999999999999/api"] {
            do {
                _ = try Resolver.webURL(string)
                Issue.record("Expected invalid endpoint")
            } catch let error as UsageError {
                #expect(!error.description.contains("secret"))
                #expect(!error.description.contains(string))
                #expect(error.description.rangeOfCharacter(from: .controlCharacters) == nil)
            } catch {
                Issue.record("Expected CLI usage error, got \(error)")
            }
        }
    }

    @Test func invalidDirectorySourceCannotUseFreshOrStaleCache() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try directoryData().write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: file.path)
        let calls = Mutex(0)
        let client = StatusClient { _ in
            calls.withLock { $0 += 1 }
            throw URLError(.cannotConnectToHost)
        }
        let invalid = try #require(URL(string: "https://user:secret@directory.example/api"))
        for age in [60.0, -1.0] {
            await #expect(throws: UsageError.self) {
                try await DirectoryLoader.load(from: invalid, cache: file, maxAge: age, client: client, now: Self.now)
            }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func networkDirectoryDropsInvalidEndpointsIndividually() async throws {
        let data = try directoryData()
        let client = StatusClient { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expectValid(try await DirectoryLoader.load(from: Self.source, cache: nil, maxAge: nil, client: client))
    }

    @Test func freshCacheUsesSameEndpointValidation() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try directoryData().write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: file.path)
        let calls = Mutex(0)
        let client = StatusClient { _ in
            calls.withLock { $0 += 1 }
            throw URLError(.cannotConnectToHost)
        }
        expectValid(try await DirectoryLoader.load(from: Self.source, cache: file, maxAge: 60, client: client, now: Self.now))
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func staleFallbackUsesSameEndpointValidation() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let data = try directoryData()
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Self.now.addingTimeInterval(-120)], ofItemAtPath: file.path)
        let calls = Mutex(0)
        let client = StatusClient { _ in
            calls.withLock { $0 += 1 }
            throw URLError(.cannotConnectToHost)
        }
        expectValid(try await DirectoryLoader.load(from: Self.source, cache: file, maxAge: 60, client: client, now: Self.now))
        #expect(calls.withLock { $0 } == 1)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func invalidSavedSpaceBatchCannotPartiallyChangeFile() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let saved = SavedSpaces(file: file)
        let first = Target(endpoint: URL(string: "https://first.example/api")!, name: "First")
        let second = Target(endpoint: URL(string: "https://second.example/api")!, name: "Second")
        let invalid = Target(endpoint: URL(string: "https://user:secret@space.example/api")!, name: nil)
        try saved.add([first])
        let before = try Data(contentsOf: file)
        #expect(throws: UsageError.self) { try saved.add([second, invalid]) }
        #expect(try Data(contentsOf: file) == before)
        #expect(throws: UsageError.self) { try saved.remove([first, invalid]) }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func savedFileRejectsInvalidURLsAndUnexpectedSuffixes() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let saved = SavedSpaces(file: file)
        for line in ["https://user:secret@space.example/api", "https://space.example/%0A",
                     "https://space.example/a\tb", "https://space.example/api unexpected"] {
            try Data((line + "\n").utf8).write(to: file)
            #expect(throws: UsageError.self) { try saved.load() }
        }
    }

    @Test func savedFileKeepsCRLFAndCommentWhitespace() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("# mine\r\nhttp://localhost/status\t# Local\r\nhttps://space.example/api  # Space\r\n".utf8).write(to: file)
        #expect(try SavedSpaces(file: file).load().map(\.name) == ["Local", "Space"])
    }
}
