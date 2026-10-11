import ArgumentParser
import CLIKit
import Foundation
import SpaceAPI
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
enum Main {
    static func main() async {
        // Broken pipes are reported by FileHandle instead of terminating in the middle of a write.
        signal(SIGPIPE, SIG_IGN)
        await SpaceState.main()
    }
}

struct SpaceState: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spacestate",
        abstract: "Show whether hackerspaces are open, using SpaceAPI.",
        discussion: """
        Give spaces by name, as listed at https://api.spaceapi.io, or by their SpaceAPI endpoint URL. \
        A name only needs to be long enough to be unique. Without spaces, the commands use your saved \
        spaces (see `spacestate add`).

        Examples:
          spacestate mainframe            Is Mainframe open?
          spacestate search berlin        Find spaces
          spacestate add mainframe        Save it, then just run `spacestate`
          spacestate watch -i 5m          Follow your saved spaces
          spacestate -q mainframe && echo open
        """,
        version: CLI.version,
        subcommands: [Show.self, Search.self, Watch.self, Add.self, Remove.self],
        defaultSubcommand: Show.self
    )
}

struct DirectoryOptions: ParsableArguments {
    @Option(help: ArgumentHelp("SpaceAPI directory used to look up names.", valueName: "url"))
    var directory = SpaceDirectory.aggregatorURL.absoluteString

    /// The default directory is cached for an hour; another one is always downloaded.
    func entries(fresh: Bool = false) async throws -> [DirectoryEntry] {
        let url = try Resolver.webURL(directory)
        let isDefault = url == SpaceDirectory.aggregatorURL
        return try await DirectoryLoader.load(
            from: url, cache: isDefault ? Paths.directoryCache() : nil, maxAge: isDefault && !fresh ? 3600 : nil)
    }

    /// Resolves names and URLs, or returns the saved spaces when there are no arguments.
    func targets(_ arguments: [String]) async throws -> [Target] {
        guard !arguments.isEmpty else { return try SavedSpaces().load() }
        var directory: [Target]?
        var targets: [Target] = []
        var problems: [String] = []
        for argument in arguments {
            if Resolver.isURL(argument) {
                targets.append(Target(endpoint: try Resolver.webURL(argument), name: nil))
                continue
            }
            if directory == nil { directory = try await entries().map(Target.init) }
            switch Resolver.resolve(argument, in: directory ?? []) {
            case .found(let target): targets.append(target)
            case .notFound: problems.append("No space is called \"\(argument)\". Try `spacestate search \(argument)`.")
            case .ambiguous(let matches): problems.append(ambiguity(argument, matches))
            }
        }
        guard problems.isEmpty else {
            try? write(problems.joined(separator: "\n\n"), to: .standardError)
            throw ExitCode.validationFailure
        }
        return targets
    }
}

func ambiguity(_ query: String, _ matches: [Target]) -> String {
    let shown = matches.prefix(10)
    let width = shown.map { Output.plain($0.name ?? "").count }.max() ?? 0
    var lines = ["\"\(query)\" matches \(matches.count) spaces:"]
    lines += shown.map { target in
        let name = Output.plain(target.name ?? "")
        return "  " + name + String(repeating: " ", count: width - name.count) + "  " + target.endpoint.absoluteString
    }
    if matches.count > shown.count { lines.append("  … and \(matches.count - shown.count) more (`spacestate search \(query)`)") }
    lines.append("Type more of the name, or use the endpoint URL.")
    return lines.joined(separator: "\n")
}

/// Reports a problem found only after parsing, without repeating the top-level usage line.
func usageFailure(_ message: String) -> ExitCode {
    try? write("Error: \(message)", to: .standardError)
    return .validationFailure
}

func write(_ text: String, to handle: FileHandle = .standardOutput) throws {
    try handle.write(contentsOf: Data((text + "\n").utf8))
}

func snapshots(_ targets: [Target]) async -> [Snapshot] {
    await withTaskGroup(of: (Int, Snapshot).self) { group in
        for (index, target) in targets.enumerated() {
            group.addTask {
                do {
                    return (index, Snapshot(target, info: try await StatusClient().space(at: target.endpoint)))
                } catch {
                    return (index, Snapshot(target, info: nil, error: String(describing: error)))
                }
            }
        }
        var results = [Snapshot?](repeating: nil, count: targets.count)
        for await (index, snapshot) in group { results[index] = snapshot }
        return results.compactMap { $0 }
    }
}

let noSavedSpaces = "No saved spaces yet. Ask for one with `spacestate <name>`, or save it with `spacestate add <name>`."

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether spaces are open.")

    @Argument(help: "Space names or endpoint URLs. Defaults to your saved spaces.")
    var spaces: [String] = []

    @Flag(name: .shortAndLong, help: "Print one JSON object per space, one per line.")
    var json = false

    @Flag(name: .shortAndLong, help: "Print nothing. Exit 0 if all are open, 1 if one is closed, 2 if one is unknown.")
    var quiet = false

    @OptionGroup var lookup: DirectoryOptions

    func validate() throws {
        if json && quiet { throw ValidationError("--json and --quiet cannot be combined.") }
    }

    func run() async throws {
        let targets = try await lookup.targets(spaces)
        guard !targets.isEmpty else {
            try write(noSavedSpaces, to: .standardError)
            if quiet { throw ExitCode(2) }
            return
        }
        let results = await snapshots(targets)
        if quiet { throw ExitCode(Output.exitCode(results)) }
        if json {
            for snapshot in results { try write(Output.json(snapshot)) }
        } else {
            try write(Output.table(results, color: terminalSupportsColor()))
        }
        if results.contains(where: \.failed) { throw ExitCode.failure }
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find spaces by name or address. Open spaces are listed first.")

    @Argument(help: "Part of a space's name, city or address.")
    var query: [String]

    @Flag(help: "List only spaces that are open now.")
    var open = false

    @Flag(name: .shortAndLong, help: "Print JSON.")
    var json = false

    @OptionGroup var lookup: DirectoryOptions

    func run() async throws {
        let text = query.joined(separator: " ")
        let rank: [SpaceStatus: Int] = [.open: 0, .closed: 1, .unknown: 2]
        let matches = try await lookup.entries(fresh: true)
            .filter {
                $0.info.name.localizedCaseInsensitiveContains(text)
                    || ($0.info.location?.address?.localizedCaseInsensitiveContains(text) ?? false)
            }
            .filter { !open || $0.info.status == .open }
            .sorted { (rank[$0.info.status]!, $0.info.name.lowercased()) < (rank[$1.info.status]!, $1.info.name.lowercased()) }
        if json {
            try write(Output.searchJSON(matches))
        } else if matches.isEmpty {
            try write("No \(open ? "open " : "")space matches \"\(text)\".", to: .standardError)
        } else {
            try write(Output.search(matches, color: terminalSupportsColor()))
        }
    }
}

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep checking spaces and report when they open or close.",
        discussion: "Prints the current state, then a line with the time whenever a space opens, closes or becomes unreachable. Stop with Ctrl+C.")

    @Argument(help: "Space names or endpoint URLs. Defaults to your saved spaces.")
    var spaces: [String] = []

    @Option(name: [.customShort("i", allowingJoined: true), .long], help: ArgumentHelp("Time between checks, such as 30s, 5m or 1h (5s to 24h).", valueName: "time"))
    var interval = "60s"

    @Option(name: [.customShort("n", allowingJoined: true), .long], help: ArgumentHelp("Stop after this many checks.", valueName: "checks"))
    var count: Int?

    @Flag(name: .shortAndLong, help: "Print one JSON object per space on every check, one per line.")
    var json = false

    @Flag(help: "Print Waybar JSON for a single space on every check.")
    var waybar = false

    @OptionGroup var lookup: DirectoryOptions

    func validate() throws {
        do { _ = try pollInterval(interval) } catch let error as UsageError { throw ValidationError(error.description) }
        if let count, count < 1 { throw ValidationError("--count must be at least 1.") }
        if json && waybar { throw ValidationError("--json and --waybar cannot be combined.") }
    }

    func run() async throws {
        let seconds = try pollInterval(interval)
        let targets = try await lookup.targets(spaces)
        guard !targets.isEmpty else { throw usageFailure(noSavedSpaces) }
        if waybar && targets.count != 1 { throw usageFailure("--waybar shows a single space; give exactly one.") }
        let color = terminalSupportsColor()
        var previous: [String: (SpaceStatus, Bool)] = [:]
        var checks = 0
        while true {
            let results = await snapshots(targets)
            if json {
                for snapshot in results { try write(Output.json(snapshot)) }
            } else if waybar {
                try write(Output.waybar(results[0]))
            } else if checks == 0 {
                try write(Output.table(results, color: color))
            } else {
                for snapshot in results where previous[snapshot.endpoint].map({ $0 != (snapshot.status, snapshot.failed) }) ?? true {
                    try write(Output.change(snapshot, color: color))
                }
            }
            for snapshot in results { previous[snapshot.endpoint] = (snapshot.status, snapshot.failed) }
            checks += 1
            if let count, checks >= count { return }
            try await Task.sleep(for: .seconds(seconds))
        }
    }
}

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save spaces, so that `spacestate` without arguments shows them.",
        discussion: "Saved spaces are kept in $XDG_CONFIG_HOME/spacestate/spaces (default ~/.config/spacestate/spaces), one endpoint per line. You can edit the file by hand.")

    @Argument(help: "Space names or endpoint URLs.")
    var spaces: [String]

    @OptionGroup var lookup: DirectoryOptions

    func run() async throws {
        var targets = try await lookup.targets(spaces)
        // An endpoint given as URL is asked for its name, so the saved list stays readable.
        for (index, target) in targets.enumerated() where target.name == nil {
            if let info = try? await StatusClient().space(at: target.endpoint) {
                targets[index] = Target(endpoint: target.endpoint, name: info.name)
            }
        }
        let saved = SavedSpaces()
        let added = try saved.add(targets)
        for target in targets {
            let name = Output.plain(target.name ?? target.endpoint.absoluteString)
            try write(added.contains(target) ? "Saved \(name)." : "\(name) is already saved.")
        }
        if !added.isEmpty { try write("Run `spacestate` to see your saved spaces (\(saved.file.path)).") }
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove saved spaces.")

    @Argument(help: "Names or endpoint URLs of saved spaces.")
    var spaces: [String]

    func run() async throws {
        let saved = SavedSpaces()
        let known = try saved.load()
        var remove: [Target] = []
        var problems: [String] = []
        for argument in spaces {
            if Resolver.isURL(argument), let url = try? Resolver.webURL(argument), let target = known.first(where: { $0.endpoint == url }) {
                remove.append(target)
                continue
            }
            switch Resolver.resolve(argument, in: known) {
            case .found(let target): remove.append(target)
            case .notFound: problems.append("\"\(argument)\" is not among your saved spaces.")
            case .ambiguous(let matches): problems.append(ambiguity(argument, matches))
            }
        }
        guard problems.isEmpty else {
            try? write(problems.joined(separator: "\n\n"), to: .standardError)
            throw ExitCode.validationFailure
        }
        try saved.remove(remove)
        for target in remove { try write("Removed \(Output.plain(target.name ?? target.endpoint.absoluteString)).") }
    }
}
