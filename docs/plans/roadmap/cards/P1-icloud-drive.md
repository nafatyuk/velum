# P1 · iCloud Drive

**Bucket** P Providers · **Part two** · **Status: planned** · **Waits for** C2 · **Runs alongside** C3, T1, A5, A6, S2 · **Feeds** S1, G2, G3

## Brief

iCloud Drive draws no menu bar icon at all [V], so the only place to see whether it is syncing is buried in Finder's sidebar. The consultant put it first among new providers ([memo](../strategy-memo.md) §2, "Next", item 1), on two facts it verified on this Mac:
- the per-file flags return real values in `~/Library/Mobile Documents/com~apple~CloudDocs`;
- `/usr/bin/brctl status` runs without special privileges.

`brctl`'s output is undocumented and noisy: parse it defensively. The launch waits for this card (G3), because "every cloud, one icon" needs a second cloud.

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off) (the protocol, and its sketch of how iCloud fits), [A4's](A4-legend-and-why-unknown.md) and [A7's](A7-onedrive-update-check.md) cards.

**The idea:** the second plug in C2's socket. If iCloud fits without bending the socket, the socket is right.

## Work

- **Find out first,** and record each answer in the hand-off:
  1. Does FSEvents deliver changes inside `Mobile Documents`?
  2. Do File Provider's progress subscriptions report iCloud transfers?
  3. With Desktop & Documents in iCloud turned on, where do those folders really live, and are their flags the same?
  4. What does `brctl status` print while idle, uploading, offline, and with storage full? Capture the shape only. Redact names before anything is written down.
  5. Which upload error does a full iCloud storage give?
  6. How much does one `brctl status` run cost, and so how often may Velum run it?
- **The adapter,** in `Providers/iCloud/`.
  - Discovery: iCloud Drive is on when the CloudDocs folder exists and reads as ubiquitous. Its display name is "iCloud Drive".
  - Running: there is no client to quit, and signed out or iCloud Drive off counts as "not available".
  - The tracker's filters: `.icloud` placeholders, as well as the shared filters.
  - The report: `brctl status`'s account-wide state, with the time it ran, parsed defensively. Output it doesn't recognize is ignored and reported, never read as healthy.
  - Actions: Open in Finder; open iCloud.com; open System Settings at iCloud.
- **Storage full is the important error.** When uploads fail for lack of space, say so plainly ("iCloud storage is full: 3 files can't upload"), in the row, the lid line and the alert.
- **The lid line, alerts and stuck files** (A1, A2, A3) cover iCloud with no special cases. If they need one, the protocol is wrong: fix it in C2's files, with the user's OK.

## Done when

- Tests cover:
  - `brctl` parsing on synthetic samples shaped like the captures, including garbage and empty output;
  - discovery when iCloud Drive is off.
- A live check on this Mac, with the user's yes:
  1. A probe file in iCloud Drive shows waiting → uploading → uploaded in `Velum --dump` and in the panel.
  2. The lid line follows it.
  3. The probe is deleted once it has settled.
- With the user's help, offline: Wi-Fi off makes the probe wait and the lid line say so.

## Ownership and limits

You own `Providers/iCloud/` and its tests. Don't touch the OneDrive adapter. Never read or show the Apple ID.

## Hand-off

_Not started._
