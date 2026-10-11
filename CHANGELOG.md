# Changelog

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
