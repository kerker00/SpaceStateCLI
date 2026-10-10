# SpaceStateCLI

A command-line client for [SpaceAPI](https://spaceapi.io), built on the independently maintained [SpaceStateKit](https://github.com/kerker00/SpaceStateKit). Search spaces, query their public state, or poll it for scripts and Waybar. No account is required.

## Build and run

Requires Swift 6.2+. The initial Linux CI target is Ubuntu 24.04 x86_64; macOS 26+ is also tested.

```sh
git clone https://github.com/kerker00/SpaceStateCLI.git
cd SpaceStateCLI
swift build -c release
.build/release/spacestate search mainframe
.build/release/spacestate status --space https://status.mainframe.io/api/spaceInfo --format json
.build/release/spacestate watch --space https://status.mainframe.io/api/spaceInfo --format ndjson
```

To install for your user, copy `.build/release/spacestate` into `~/.local/bin` and ensure that directory is in `PATH`.

The Linux CI artifact is a dynamically linked Ubuntu 24.04 x86_64 binary. Keep the Swift 6.2 runtime installed on the target machine, along with its Foundation networking dependencies (including libcurl/TLS/ICU). It is a CI artifact, not yet a standalone distribution package. Static binaries, ARM64 and fresh-system packaging acceptance are follow-up work.

## Commands

```text
spacestate search <query> [--directory <url>] [--format text|json]
spacestate status --space <endpoint> [--format text|json]
spacestate watch --space <endpoint> [--format text|ndjson|waybar-json]
                 [--interval <seconds>] [--count <updates>]
```

Search matches space names and addresses, case-insensitively. The default source is the SpaceAPI aggregator. `--directory` supports other aggregators in the same format and local test servers. Direct space endpoints accept HTTP and HTTPS. Embedded URL credentials are rejected.

`watch` polls immediately and then every 60 seconds by default. The allowed interval is 5–86400 seconds. `--count` limits the number of emitted updates, including failures. Stop an unlimited watch with Ctrl+C. It emits no desktop notifications. SpacePush streams and APNs registration are outside this first CLI version.

## JSON contract, version 1

`status --format json` returns one object; `watch --format ndjson` emits one object per line:

```json
{"schemaVersion":1,"endpoint":"https://example.org/spaceapi.json","name":"Example Space","status":"open","network":"ok","fetchedAt":"2026-10-10T20:00:00Z","observedAt":"2026-10-10T20:00:00Z"}
```

- `status`: `open`, `closed`, or `unknown`. Missing published state is `unknown` even when networking succeeded.
- `network`: `ok` or `error`. A watch failure emits `unknown` and an `error` string; the previous successful state is not repeated as current.
- `fetchedAt`: time this response was successfully retrieved; omitted for failure. For search, this is the aggregator retrieval time.
- `observedAt`: time the snapshot was produced; `lastChange`: optional endpoint-reported state timestamp. Endpoint freshness cannot be guaranteed from retrieval time alone.
- Optional fields `name`, `message`, `lastChange`, `fetchedAt`, and `error` are omitted when unavailable. Dates use ISO 8601 UTC.
- Search JSON is `{ "schemaVersion": 1, "spaces": [...] }`, with the same snapshot objects.

Stdout contains only data; stderr contains diagnostics. Exit code 0 means command completion, 1 means a network/data/output failure, and 2 means invalid arguments. A watch continues after network failures and emits error snapshots; completion with `--count` exits 0 even if a sample failed. Neither a closed space nor an empty search is a command error.

Waybar output follows Waybar's own `text`, `tooltip`, `class`, and `alt` contract. `class` is `open`, `closed`, `unknown`, or `error`; tooltip markup is escaped.

## Waybar

Add `custom/spacestate` to your module list and configure:

```json
"custom/spacestate": {
  "exec": "spacestate watch --space https://status.mainframe.io/api/spaceInfo --format waybar-json",
  "return-type": "json",
  "restart-interval": 5,
  "escape": true
}
```

This is a persistent polling process. Do not add Waybar's `interval` setting to it. Style `#custom-spacestate.open`, `.closed`, `.unknown`, and `.error` in your Waybar CSS.

## Development

The normal build pins SpaceStateKit to `0.1.0`. To work on sibling checkouts:

```sh
SPACESTATEKIT_PATH=../SpaceStateKit swift test
SPACESTATEKIT_PATH=../SpaceStateKit swift build -c release
python3 IntegrationTests/run.py
```

CI builds against the published Kit tag and runs unit tests plus real HTTP command tests. [CHANGELOG.md](CHANGELOG.md) records CLI and JSON contract changes. Update the pinned package version deliberately when adopting a Kit release.

MIT; see [LICENSE.MD](LICENSE.MD).
