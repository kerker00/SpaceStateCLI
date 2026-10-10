import Foundation
import CLIKit
import SpaceAPI
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
struct SpaceStateCLI {
    static let help = """
    spacestate 0.1.0 — query SpaceAPI endpoints

    spacestate search <query> [--directory <url>] [--format text|json]
    spacestate status --space <endpoint> [--format text|json]
    spacestate watch --space <endpoint> [--format text|ndjson|waybar-json]
                     [--interval <seconds>] [--count <updates>]

    watch polls immediately, then every 60 seconds by default (minimum 5).
    Exit codes: 0 success, 1 network/data error, 2 invalid arguments.
    --help    Show this help
    --version Show the version
    """

    static func write(_ line: String, to handle: FileHandle = .standardOutput) throws {
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    static func main() async {
        // Broken pipes are reported by FileHandle instead of terminating in the middle of a write.
        signal(SIGPIPE, SIG_IGN)
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case .help: try write(help)
            case .version: try write("spacestate 0.1.0")
            case .search:
                let entries = try SpaceDirectory.decode(await StatusClient().data(
                    from: options.directory, maximumBytes: StatusClient.maxDirectoryResponseBytes))
                let matches = entries.filter {
                    $0.info.name.localizedCaseInsensitiveContains(options.query)
                        || ($0.info.location?.address?.localizedCaseInsensitiveContains(options.query) ?? false)
                }
                let output = try Output.search(matches, format: options.format)
                if !output.isEmpty { try write(output) }
            case .status:
                let endpoint = options.endpoint!
                let info = try await StatusClient().space(at: endpoint)
                try write(Output.snapshot(Snapshot(endpoint: endpoint, info: info), format: options.format))
            case .watch:
                var updates = 0
                while true {
                    try Task.checkCancellation()
                    let snapshot: Snapshot
                    do {
                        let info = try await StatusClient().space(at: options.endpoint!)
                        snapshot = Snapshot(endpoint: options.endpoint!, info: info)
                    } catch {
                        try Task.checkCancellation()
                        let message = String(describing: error)
                        try write("spacestate: \(Output.plain(message))", to: .standardError)
                        snapshot = Snapshot(endpoint: options.endpoint!, info: nil, error: message)
                    }
                    try write(Output.snapshot(snapshot, format: options.format))
                    updates += 1
                    if let count = options.count, updates >= count { break }
                    try await Task.sleep(for: .seconds(options.interval))
                }
            }
        } catch let error as UsageError {
            try? write("spacestate: \(error.description)\nUse --help for usage.", to: .standardError)
            exit(2)
        } catch {
            try? write("spacestate: \(Output.plain(String(describing: error)))", to: .standardError)
            exit(1)
        }
    }
}
