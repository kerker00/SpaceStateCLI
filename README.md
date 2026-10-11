# SpaceStateCLI

A command-line client for [SpaceAPI](https://spaceapi.io), built on the independently maintained [SpaceStateKit](https://github.com/kerker00/SpaceStateKit). Ask by name whether a space is open, save your spaces, follow them, or feed scripts and Waybar. No account is required.

## Build and run

Requires Swift 6.2+. The initial Linux CI target is Ubuntu 24.04 x86_64; macOS 26+ is also tested.

### Prerequisites

**macOS:** Xcode 26 or its Command Line Tools (`xcode-select --install`).

**Ubuntu 24.04:** Swift is not in the distribution's package sources. Install the packages the Swift toolchain needs, then Swift itself with [swiftly](https://www.swift.org/install/linux/):

```sh
sudo apt-get update
sudo apt-get install -y curl ca-certificates git gnupg2 binutils unzip tzdata pkg-config \
  libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libstdc++-13-dev \
  libncurses-dev libpython3-dev libsqlite3-0 libxml2-dev libz3-dev zlib1g-dev

curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
./swiftly init --quiet-shell-followup
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
hash -r
swiftly install --use 6.2
swift --version
```

`swiftly init` prints any system packages that are still missing; install them and run `swift --version` again. Other distributions: see [swift.org/install](https://www.swift.org/install/linux/) for their package list. `python3` is needed only for the integration tests.

**Without installing Swift:** build in the official container, as CI does. Only Docker is needed:

```sh
docker run --rm -v "$PWD":/src -w /src swift:6.2-noble swift build -c release
```

The resulting binary needs the Swift runtime libraries (see below), so run it inside that container or on a machine with Swift 6.2 installed.

### Build

```sh
git clone https://github.com/kerker00/SpaceStateCLI.git
cd SpaceStateCLI
swift build -c release
.build/release/spacestate mainframe
```

To install for your user, copy `.build/release/spacestate` into `~/.local/bin` and ensure that directory is in `PATH`.

The Linux CI artifact is a dynamically linked Ubuntu 24.04 x86_64 binary. Keep the Swift 6.2 runtime installed on the target machine, along with its Foundation networking dependencies (including libcurl/TLS/ICU). It is a CI artifact, not yet a standalone distribution package. Static binaries, ARM64 and fresh-system packaging acceptance are follow-up work.

Shell completion for zsh, bash or fish:

```sh
spacestate --generate-completion-script zsh > ~/.zfunc/_spacestate   # or bash, fish
```

## Usage

```text
$ spacestate mainframe
Mainframe  ● open     for 36 min  Open!

$ spacestate add mainframe leinelab
Saved Mainframe.
Saved LeineLab.

$ spacestate
Mainframe  ● open     for 36 min  Open!
LeineLab   ○ closed   for 2 h
```

| Command | What it does |
| --- | --- |
| `spacestate [<space> ...]` | Show whether spaces are open. Without spaces: your saved spaces. |
| `spacestate search <text> [--open]` | Find spaces by name, city or address; open ones first. |
| `spacestate watch [<space> ...] [-i 5m] [-n <checks>]` | Print the current state, then a timed line whenever a space opens, closes or becomes unreachable. |
| `spacestate add <space> ...` | Save spaces. |
| `spacestate remove <space> ...` | Remove saved spaces. |

A space is a name or a SpaceAPI endpoint URL. Names come from the [SpaceAPI directory](https://api.spaceapi.io), ignoring case and accents: an exact name wins, then a unique beginning, then a unique part of the name or host, so `spacestate main` finds Mainframe. When a name fits several spaces, the command lists them and stops; it never guesses. The directory is cached for an hour in `$XDG_CACHE_HOME/spacestate/` (default `~/.cache/spacestate/`); `--directory <url>` uses another aggregator in the same format. Endpoint URLs must be HTTP or HTTPS without embedded credentials.

`spacestate --help` and `spacestate help <command>` describe every option.

### Saved spaces

The config file is optional: `$XDG_CONFIG_HOME/spacestate/spaces` (default `~/.config/spacestate/spaces`). `add` and `remove` maintain it, and it can be edited by hand. One endpoint per line, an optional `# name` after it, and lines starting with `#` are comments:

```text
https://status.mainframe.io/api/spaceInfo  # Mainframe
https://leinelab.org/api/spaceapi.json  # LeineLab
```

### Scripts

- `-q` / `--quiet` prints nothing and answers with the exit code: 0 when every space is open, 1 when one is closed, 2 when one is unknown or unreachable. `spacestate -q mainframe && notify-send "Mainframe is open"`
- `-j` / `--json` prints one JSON object per space and line (see below); `watch --json` does so on every check.
- Colors appear only on a terminal and honour `NO_COLOR`.

Exit codes otherwise: 0 success, 1 network/data/output failure (including a space that could not be reached), 64 invalid arguments or a name that does not resolve. A closed space or an empty search is not an error. `watch` keeps running after network failures, reporting them; with `-n` it exits 0 when done.

## JSON contract, version 1

`spacestate --json` and `watch --json` emit one object per line:

```json
{"schemaVersion":1,"endpoint":"https://example.org/spaceapi.json","name":"Example Space","status":"open","network":"ok","fetchedAt":"2026-10-10T20:00:00Z","observedAt":"2026-10-10T20:00:00Z"}
```

- `status`: `open`, `closed`, or `unknown`. Missing published state is `unknown` even when networking succeeded.
- `network`: `ok` or `error`. A failure emits `unknown` and an `error` string; the previous successful state is not repeated as current. `name` then comes from the directory or the saved spaces, if known.
- `fetchedAt`: time this response was successfully retrieved; omitted for failure. For search, this is the aggregator retrieval time.
- `observedAt`: time the snapshot was produced; `lastChange`: optional endpoint-reported state timestamp. Endpoint freshness cannot be guaranteed from retrieval time alone.
- Optional fields `name`, `message`, `lastChange`, `fetchedAt`, and `error` are omitted when unavailable. Dates use ISO 8601 UTC.
- `search --json` prints `{ "schemaVersion": 1, "spaces": [...] }`, with the same snapshot objects.

Stdout contains only data; stderr contains diagnostics.

## Waybar

Add `custom/spacestate` to your module list and configure:

```json
"custom/spacestate": {
  "exec": "spacestate watch --waybar mainframe",
  "return-type": "json",
  "restart-interval": 5,
  "escape": true
}
```

This is a persistent polling process (every 60 s; change it with `-i`). Do not add Waybar's `interval` setting to it. `--waybar` shows exactly one space: give it, or save exactly one. The output follows Waybar's `text`, `tooltip`, `class` and `alt` contract; `class` is `open`, `closed`, `unknown`, or `error`, and tooltip markup is escaped. Style `#custom-spacestate.open`, `.closed`, `.unknown`, and `.error` in your Waybar CSS.

## Development

The normal build pins SpaceStateKit to `0.1.0`. To work on sibling checkouts:

```sh
SPACESTATEKIT_PATH=../SpaceStateKit swift test
SPACESTATEKIT_PATH=../SpaceStateKit swift build -c release
python3 IntegrationTests/run.py
```

CI builds against the published Kit tag and runs unit tests plus real HTTP command tests. [CHANGELOG.md](CHANGELOG.md) records CLI and JSON contract changes. Update the pinned package version deliberately when adopting a Kit release.

MIT; see [LICENSE.MD](LICENSE.MD).
