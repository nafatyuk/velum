# T1 · `velumctl`

**Bucket** T Tools and system surfaces · **Part two** · **Status: planned** · **Waits for** C2 · **Runs alongside** P1, C3, A5, A6, S2 · **Feeds** T2, T3, R3

## Brief

Scripts, Raycast and backup jobs want to ask "is everything synced?" without opening a panel. The consultant ranked a `velumctl status --json` fifth among the feature ideas ([memo](../strategy-memo.md) §3, idea 5; §2, "Next", "Also"). Two models exist:
- `Velum --dump` already prints what the panel would show;
- Crisp ships `crispctl` inside its app bundle [V].

Crisp's `RELEASING.md` records a lesson for Homebrew. A cask's `binary` line can only be added after a release that contains the tool; added earlier, it breaks every `brew install`.

The running app holds the live state: its FSEvents streams, its pending list, its transfers. A separate tool can't rebuild that state by itself. Suggested route: on every refresh, the app writes a small snapshot file, and `velumctl` reads it and reports its age. The same snapshot later feeds T2's Shortcuts and T3's widget.

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's](C2-sync-provider-protocol.md#hand-off) and [A1's](A1-safe-to-close-the-lid.md#hand-off) hand-offs, and `DebugDump` in `Entry.swift`.

**The idea:** a departures board. The station (Velum) updates it; anyone walking past (a script) can read it, and the board shows when it was last updated.

## Work

- **The snapshot.**
  - After each refresh, the app writes `~/Library/Application Support/Velum/status.json`, with an atomic write and permissions 0600.
  - Contents: a schema version, when it was written, the lid verdict, and each account's provider, name, state, headline, source, age and counts, with the pending files (names included, since the file stays on this Mac).
- **`Sources/velumctl/`,** a second executable product, copied to `Velum.app/Contents/MacOS/velumctl` by `build.sh`. Its commands:
  - `velumctl status [--json]`
  - `velumctl lid [--json]`. Its exit code is the answer: 0 safe, 1 pending, 2 failing, 3 unknown or not running.
  - `velumctl pending [--json]`
  - `velumctl --version`
- **Missing or old means unknown.** If Velum isn't running, or the snapshot is older than two refresh intervals, the answer is "unknown", never the last good answer.
- **Install:** the README gives the one-line link into a folder on your PATH. R3 adds the cask's `binary` line after a release that ships the tool.

## Done when

- Tests use made-up snapshots and cover:
  - every exit code;
  - the JSON schema (its keys don't change silently);
  - a stale snapshot giving unknown;
  - a missing file;
  - a snapshot with a newer schema.
- Live, on this Mac: `velumctl lid` agrees with the panel. With the user's yes, a probe file flips it to pending and back; the probe is deleted afterwards.

## Ownership and limits

You own:
- `Sources/velumctl/`;
- its product in `Package.swift`;
- its copy step in `build.sh`;
- the snapshot writer, a new file plus one line in the `Store`'s refresh.

The tool only reads. No commands that change anything (pause, restart) for now.

## Hand-off

_Not started._
