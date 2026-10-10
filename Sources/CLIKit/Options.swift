import Foundation
import SpaceAPI

public struct UsageError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Options: Sendable {
    public enum Command: String, Sendable { case search, status, watch, help, version }
    public let command: Command
    public var query = ""
    public var endpoint: URL?
    public var directory = SpaceDirectory.aggregatorURL
    public var format = "text"
    public var interval: Double = 60
    public var count: Int?

    public init(_ arguments: [String]) throws {
        guard let first = arguments.first else { command = .help; return }
        if first == "--help" || first == "-h" { command = .help; return }
        if first == "--version" { command = .version; return }
        guard let command = Command(rawValue: first), ![.help, .version].contains(command) else {
            throw UsageError("Unknown command: \(first)")
        }
        if arguments.dropFirst().contains("--help") { self.command = .help; return }
        self.command = command
        var index = 1
        var query: [String] = []
        while index < arguments.count {
            let argument = arguments[index]
            if !argument.hasPrefix("--") {
                guard command == .search else { throw UsageError("Unexpected argument: \(argument)") }
                query.append(argument)
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { throw UsageError("Missing value for \(argument)") }
            let value = arguments[index + 1]
            switch argument {
            case "--space" where command != .search: endpoint = try Self.webURL(value)
            case "--directory" where command == .search: directory = try Self.webURL(value)
            case "--format": format = value
            case "--interval" where command == .watch:
                guard let seconds = Double(value), seconds.isFinite, seconds >= 5, seconds <= 86400 else {
                    throw UsageError("--interval must be between 5 and 86400 seconds")
                }
                interval = seconds
            case "--count" where command == .watch:
                guard let number = Int(value), number > 0 else { throw UsageError("--count must be a positive integer") }
                count = number
            default: throw UsageError("Unknown option: \(argument)")
            }
            index += 2
        }
        self.query = query.joined(separator: " ")
        if command == .search && self.query.isEmpty { throw UsageError("search requires a query") }
        if command != .search && endpoint == nil { throw UsageError("\(command.rawValue) requires --space <endpoint>") }
        let formats = command == .watch ? ["text", "ndjson", "waybar-json"] : ["text", "json"]
        guard formats.contains(format) else { throw UsageError("Supported formats: \(formats.joined(separator: ", "))") }
    }

    private static func webURL(_ string: String) throws -> URL {
        guard let components = URLComponents(string: string),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, let url = components.url else {
            throw UsageError("Expected an HTTP(S) URL without embedded credentials")
        }
        return url
    }
}
