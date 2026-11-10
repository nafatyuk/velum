# A7 · Notice when OneDrive changes underneath

**Bucket** A Assurance · **Part one** · **Status: planned** · **Waits for** C2 · **Runs alongside** A3, A4, R2 · **Feeds** S2, P4

## Brief

The consultant's first risk is that OneDrive's internals change ([memo](../strategy-memo.md) §6, risk 1). Its answer:
- the generic tier as a floor (C3);
- provenance on every status (C1, C2);
- a tested-version note;
- degrading to `.unknown`.

This card is the tested-version note and the degrading.

Velum reads several OneDrive internals that Microsoft never promised to keep:
- the hourly `SyncDiagnostics.log` and its `SyncProgressState` codes (0 and 16777216 healthy, 65536 paused, 8194 not syncing, 1854 issue);
- the activity database `UXDatabase.db`: the columns of its `history_list` table, and its item types (4 downloaded, 5 uploaded, 6 deleted, 10 and 11 moved, 12 restored);
- the settings `.ini` files (`libraryScope` lines) used to find accounts;
- the process name;
- the icon's Accessibility text.

The README says "tested with OneDrive 26.204"; this Mac has 26.204.1019.

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off), the OneDrive adapter, and [A4's card](A4-legend-and-why-unknown.md) (it shows the reasons this card produces).

**The idea:** a canary. Before trusting the mine's air, check the bird. If OneDrive moved a wall, Velum stops reading behind it and says so, instead of reading the wrong room.

## Work

- **`Providers/OneDrive/Compatibility.swift`: one check per internal.** Each check answers fine, missing, or changed (unexpected columns, an unknown code, a file it can't parse). It runs:
  - at launch;
  - whenever OneDrive's version changes (`CFBundleShortVersionString` of the installed OneDrive app).
- **The tested versions** live in code, and the README carries one line about them.
- **A failed check drops that evidence; Velum never guesses.**
  - Statuses that depended on it become `.unknown`, with a reason A4 shows, such as "OneDrive 27.0 changed its activity database. Velum shows what macOS reports."
  - The activity list hides itself, with one line saying why.
  - One alert per new OneDrive version, through A2's notifier.
- **New values count as unknown, never healthy.** An unrecognized item type or `SyncProgressState` code reads as unknown, never as healthy, and it is recorded.
- **`--dump`** prints the check's results, and S2's report includes them.

## Done when

- Tests use synthetic fixtures built inside the test, never the user's real files:
  - an SQLite file with a renamed column;
  - a log with an unknown code;
  - a missing `.ini`;
  - a newer version string.

  Each one degrades exactly as described, and none ends in a green status or a safe lid line.
- On this Mac, read-only: `Velum --dump` shows every check passing for OneDrive 26.204.

## Ownership and limits

You own:
- `Providers/OneDrive/Compatibility.swift`;
- the adapter's calls into it;
- the README's tested-version line.

Never edit OneDrive's files. Never use `log show` (it returns nothing here).

## Hand-off

_Not started._
