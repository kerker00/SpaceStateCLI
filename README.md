# SpaceStateCLI

A command-line client for [SpaceAPI](https://spaceapi.io), built on the independently maintained [SpaceStateKit](https://github.com/kerker00/SpaceStateKit). Ask by name whether a space is open, see how to get in and reach it, save your spaces, follow them, or feed scripts and Waybar. No account is required.

Status and observation meanings follow the [shared English/German terminology](https://github.com/kerker00/SpaceState/blob/dev/docs/TERMINOLOGY.md).
CLI output stays English: `open`, `closed` and `unknown` are also stable JSON and
Waybar values. The legacy JSON field `checkedAt` means the original observation;
`attemptedAt` is the latest attempt. `keymasters` and the “Keymasters” heading
retain the SpaceAPI collection name for keyholder contacts.

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

$ spacestate info leinelab
LeineLab  ○ closed   for 2 h
  Website     https://leinelab.org
  Address     Hüttenstraße 22B, 30165 Hannover, Germany (DE)
  Access      If sign is red, space is locked. …
  Contact     Email     anfragen@leinelab.org
              Mastodon  @leinelab@chaos.social
  Feeds       Calendar  https://leinelab.org/…/dokuwiki-56d0397423f22.ics
              Wiki      https://leinelab.org/feed.php
  Projects    https://github.com/LeineLab
  Endpoint    https://leinelab.org/api/spaceapi.json
```

| Command | What it does |
| --- | --- |
| `spacestate [<space> ...]` | Show whether spaces are open. Without spaces: your saved spaces. |
| `spacestate info [<space> ...]` | Show available details: website, address, access hint, contacts, keymasters, feeds, links, projects. |
| `spacestate search <text> [--open]` | Find spaces by name, city or address; open ones first. |
| `spacestate watch [<space> ...] [-i 5m] [-n <checks>]` | Print the current state, then changes, failures and expiry between checks. |
| `spacestate add <space> ...` | Save spaces. |
| `spacestate remove <space> ...` | Remove saved spaces. |

A space is a name or a SpaceAPI endpoint URL. Names come from the [SpaceAPI directory](https://api.spaceapi.io), ignoring case and accents: an exact name wins, then a unique beginning, then a unique part of the name or host, so `spacestate main` finds Mainframe. When a name fits several spaces, the command lists them and stops; it never guesses. The directory is cached for an hour in `$XDG_CACHE_HOME/spacestate/` (default `~/.cache/spacestate/`); `--directory <url>` uses another aggregator in the same format. Endpoint URLs must be absolute HTTP(S) URLs with a host and a port from 1 to 65535 when specified, without embedded credentials or literal/percent-encoded control characters. The same Kit validation applies to directory and saved-space entries. Endpoint validation errors exit with 64 and do not echo the supplied URL.

`info` shows fields decoded by SpaceStateKit. Text output lists keymasters by name or IRC nickname; `info --json` also includes their contact details.

`spacestate --help` and `spacestate help <command>` describe every option.

### Saved spaces

The config file is optional: `$XDG_CONFIG_HOME/spacestate/spaces` (default `~/.config/spacestate/spaces`). `add` and `remove` maintain it, and it can be edited by hand. One endpoint per line, an optional `# name` after it, and lines starting with `#` are comments:

```text
https://status.mainframe.io/api/spaceInfo  # Mainframe
https://leinelab.org/api/spaceapi.json  # LeineLab
```

### Scripts

- `-q` / `--quiet` prints nothing and answers with the exit code: 0 when every space is open, 1 when one is closed, 2 when one is unknown or unreachable. `spacestate -q mainframe && notify-send "Mainframe is open"`
- `-j` / `--json` prints JSON (see below).
- Colors appear only on a terminal and honour `NO_COLOR`.

Exit codes otherwise: 0 success, 1 network/data/output failure (including a space that could not be reached by `show` or `info`), 64 invalid arguments or a name that does not resolve. A closed space or an empty search is not an error. `watch` keeps running after network failures, reporting them; with `-n` it exits 0 when done.

## JSON

`show --json` and `search --json` print an array with one object per space; `watch --json` prints one object per space and check, plus changed expiry records, one per line:

```json
{"attemptedAt":"2026-10-13T21:31:24Z","checkedAt":"2026-10-13T21:31:25Z","endpoint":"https://status.mainframe.io/api/spaceInfo","expiresAt":"2026-10-13T21:46:25Z","freshness":"current","message":"Open!","name":"Mainframe","receivedAt":"2026-10-13T21:31:25Z","reportedStatus":"open","since":"2026-10-13T15:57:08Z","source":"direct","status":"open"}
```

- `status`: the effective current state, `open`, `closed`, or `unknown`. Missing, future, expired or unproven observations cannot provide a current open/closed flag. A space that publishes no state remains `unknown` even with current timing.
- `reportedStatus`: the last known published state, which may differ from the effective status. `freshness` is `current`, `stale` or `unknown`; age and read failure are distinct.
- `error`: set when the endpoint or directory read fails; effective `status` is then `unknown`. A watch or directory fallback may retain last known data and source times. `name` comes from the directory or saved spaces when no successful value is available.
- `since`: when the space says its state last changed; this does not prove freshness. `checkedAt` is now only a usable original successful observation: direct receipt, or directory `lastSeen`. It is absent when the source time is missing, invalid or future, and on a first failed read. It is never replaced with the client's current time to fill missing evidence.
- `attemptedAt`: the client check/attempt, including an unsuccessful read or cache lookup. `receivedAt`: successful client receipt, retained from a cached directory or earlier successful watch read. `expiresAt`: the conservative observation limit; reevaluating a retained snapshot changes status/freshness without changing these times.
- `source` identifies the direct or aggregator read path. Optional values are omitted when absent or unusable. Dates use ISO 8601 UTC.

This is an unreleased JSON-contract change: consumers that assumed `checkedAt`
always existed must handle its absence and use `attemptedAt` for attempts.
Direct reads use Kit 0.3.2's 15-minute retention limit. A directory's advertised
`X-SpacePush-Max-Data-Age` is honored; absent policy uses the same default, while
malformed policy cannot provide a current flag. Downloading or reusing the list
does not refresh its original per-space observations. `search --open` and ordering
use effective current states. Directory validation failures remain unknown.

Name caches now store their original successful receipt, source URL, age policy
and body together. Touching the file does not refresh that receipt; old raw-array
caches remain readable using their file time and original `lastSeen`. A failed
refresh can supply cached names with a visible error, never current opening flags.
Older CLI binaries may refetch an envelope cache; saved-space files are unchanged.

`watch` retains the last good in-memory value on a failed check, labelling its
current state unknown and preserving source times. During long polling intervals,
expiry emits unknown before the next request; a delayed timer also emits this
transition before starting a new read. `-n` counts network check rounds, not expiry
events. When watch exits, consumers must still honor the advertised expiry of its
last output. Direct HTTP receipt proves a usable answer was received, not a fresh
physical measurement. Text and Waybar distinguish stale or unproven observations
from an unreachable endpoint; Waybar's existing open/closed/unknown/error classes
are retained.

`info --json` prints an array of the same objects, extended by whatever the space publishes: `website`, `logo`, `location` (`address`, `latitude`, `longitude`, `timezone`, `country`, `hint`), `icons` (`open`, `closed`), `contact`, `keymasters`, `feeds` (`kind`, `url`, `type`), `links`, `projects`, `linkedSpaces` and `apiCompatibility`. Parts the space does not publish are left out.

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

In the local multi-repository SpaceState workspace, the shared roadmap is `../Plan.md`. It is a workspace file, not part of this public repository.

The normal build pins SpaceStateKit to `0.3.2`. To work on sibling checkouts:

```sh
SPACESTATEKIT_PATH=../SpaceStateKit swift test
SPACESTATEKIT_PATH=../SpaceStateKit swift build -c release
python3 IntegrationTests/run.py
```

CI builds against the published Kit tag and runs unit tests plus real HTTP command tests. [CHANGELOG.md](CHANGELOG.md) records CLI and JSON changes. Update the pinned package version deliberately when adopting a Kit release.

MIT; see [LICENSE.MD](LICENSE.MD).
