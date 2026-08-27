# Glob Pattern Spec (E1)

`path_pattern` in `rule.add` is a glob matched against the event's `targetPath`.
This is the canonical glob semantics shared across the Fusion ecosystem event layer.

## Wildcards

| token | meaning |
|-------|---------|
| `*`   | matches any run of characters **within a single path segment** (does not cross `/`) |
| `**`  | matches across directory boundaries (any number of segments, including zero) |
| `?`   | matches exactly one character that is **not** `/` |
| literal | matches itself |

## Rules

- An empty or absent pattern matches **every** path (match-all).
- `*` never matches `/`. `/src/*` matches `/src/a.swift` but not `/src/sub/a.swift`.
- `**` matches zero-or-more path segments. `/src/**/*.swift` matches `/src/a.swift`,
  `/src/sub/a.swift`, `/src/x/y/a.swift`.
- `**` may be followed by `/`; the slash is consumed as a segment separator.
  `/src/**/a.swift` matches `/src/a.swift` and `/src/x/a.swift`.
- `?` does not match `/`. `/src/a?swift` matches `/src/axswift` but not `/src/a/swift`.

## Examples

| pattern | matches | does not match |
|---------|---------|----------------|
| `/src/*.swift` | `/src/a.swift` | `/src/sub/a.swift`, `/out/a.swift` |
| `/src/**/*.swift` | `/src/a.swift`, `/src/x/y/a.swift` | `/out/a.swift` |
| `/Users/dahai/src/**/*.swift` | `/Users/dahai/src/a.swift` | `/Users/dahai/out/a.swift` |
| `*.log` | `app.log` | `dir/app.log` |
| `/x/a?` | `/x/ab` | `/x/a/`, `/x/a` |

## Implementation

`Sources/fusion-event/Glob.swift` — recursive backtracking matcher over
`[Character]`. Single `*` stops at `/`; `**` recurses across `/`; `?` rejects `/`.
No regex, no brace expansion, no negation — keep it minimal and portable across
ecosystem consumers so rule semantics are identical everywhere.
