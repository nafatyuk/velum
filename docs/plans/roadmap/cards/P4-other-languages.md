# P4 · OneDrive's icon text in other languages

**Bucket** P Providers · **Part three: later, only on real user requests** · **Status: later** · **Waits for** C2 · **Runs alongside** T2, T3 · **Feeds** nothing

## Brief

Exact status, the opt-in Accessibility path, reads the text of OneDrive's icon and sorts it with English keywords (`SyncState.classify` in `Model.swift`): "synced", "up to date" and "online" mean healthy. Anything else is unknown, unless another English keyword matches. On a Mac set to French or Japanese, exact status would therefore read every account as unknown. That is safe, because it never gives a false "synced", but it is useless. The consultant listed localized classification as a Later item ([memo](../strategy-memo.md) §2, "Later").

The permission-free tier doesn't depend on language at all. This card only matters for people who turn on exact status, and only for non-English users, so it waits for one to ask.

Read the [campaign rules](../README.md#rules-every-card-follows), `LiveStatus.swift`, `SyncState.classify`, and C2's hand-off (where classification ends up).

**The idea:** read the label in the language it was printed in, using the printer's own dictionary.

## Work

- **Find out:** where the installed OneDrive app keeps its translated status strings (`.lproj` string tables, or compiled `.loctable` files), and which keys hold the status lines.
- **Classify through OneDrive's own tables, at run time.** Look up the status keys in the installed app's table for the user's language, and map them to states. Never copy Microsoft's strings into Velum's repo.
- **Fall back to unknown, as today,** when a table or key is missing (A7 reports it).

## Done when

- Tests with synthetic tables cover: a match, a missing key, a missing table.
- With the user's OK, live: OneDrive run once in another language (`-AppleLanguages`, which restarts OneDrive) classifies correctly with exact status on.

## Ownership and limits

You own the OneDrive adapter's classification and its tests.

## Hand-off

_Not started._
