# Changelog

## Unreleased

- Use SpaceStateKit's shared endpoint validation for manual URLs, saved spaces and
  directory sources before network or cache access. Invalid saved-space batches
  leave the file unchanged, and errors do not repeat credentials or control characters.
- Reject unexpected trailing text in saved-space lines while retaining CRLF,
  whitespace separators and optional `#` comments.
- Classify CLI input/configuration validation errors as exit code 64, including
  invalid endpoint URLs, while retaining the parser's help, version and completion commands.
- Directory entries from network, fresh cache and stale fallback use the same
  per-entry endpoint validation. Adopts the exact published Kit 0.3.1 source release.

## 0.3.0 — 2026-10-11

Breaking: the JSON output is simpler.

- New `info` command: website, address with country, access hint, contacts, keymasters, feeds, links, projects and linked spaces, as text or JSON.
- JSON: `show --json` and `search --json` print an array; `watch --json` keeps one object per line. `schemaVersion`, `network`, `fetchedAt` and `observedAt` are gone; `lastChange` is now `since`, and `checkedAt` tells when the state was fetched (for `search`: when the aggregator last reached the space). `error` alone marks an unreachable space.
- Uses SpaceStateKit 0.2.0.

## 0.2.0 — 2026-10-11

Breaking: the command line is redesigned for people; the 0.1.0 commands and options are gone.

- Spaces are given by name (`spacestate mainframe`) or endpoint URL; ambiguous names list the candidates instead of guessing.
- Optional saved spaces in `$XDG_CONFIG_HOME/spacestate/spaces`, managed with `add` and `remove`; `spacestate` without arguments shows them.
- `show` is the default command and takes several spaces; aligned, colored output with the time since the last change.
- `watch` prints the current state, then only changes with the time; `-i` accepts `30s`, `5m`, `1h`; `-n` limits the checks.
- `search` lists open spaces first; `--open` filters.
- `--json`/`-j` replaces `--format json|ndjson`, `--waybar` replaces `--format waybar-json`, `-q` answers through the exit code.
- The directory is cached for an hour for name lookups.
- Invalid arguments exit with 64 (was 2). Help, errors and shell completion come from swift-argument-parser.
- JSON contract version 1 is unchanged; `name` is now also set on failures when it is known.

## 0.1.0 — 2026-10-10

- Initial `search`, `status` and polling `watch` commands.
- Human-readable, versioned JSON, NDJSON and Waybar output.
- Separate diagnostics, documented exit codes and explicit network error samples.
- Pin SpaceStateKit 0.1.0; support a local sibling checkout for development.
- Add Linux/macOS CI, parser/output tests and real HTTP command tests.
