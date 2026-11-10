# A4 · What each light means, and how old it is

**Bucket** A Assurance · **Part one** · **Status: planned** · **Waits for** C2 · **Runs alongside** A3, A7, R2 · **Feeds** P1, C3, S1 (they reuse its reason line and age text)

## Brief

Velum's icon gets a badge for syncing, paused, sync issue, not running and error. "Up to date" and "unknown" both show a plain cloud (`StatusIcon` in `AppDelegate.swift`). In the panel, an unknown account shows a grey question mark and a source label, but not *why* Velum doesn't know or what would let it know. Statuses that come from OneDrive's hourly report show the report's time, but nothing marks a report that is three hours old as old.

The consultant's fourth idea ([memo](../strategy-memo.md) §3): an icon legend and a "why is it unknown?" row, which "turns `.unknown` into trust". The memo also named the permission-free tier's main risk: the up-to-an-hour lag for paused and offline, which the app should answer by showing the status's age (§2, "Now", row 1).

Read the [campaign rules](../README.md#rules-every-card-follows), [C1's](C1-permission-free-tracking.md#hand-off) and [C2's](C2-sync-provider-protocol.md#hand-off) hand-offs, `StatusIcon`, and `AccountRow`, `StatePlatter` and `LidRow` in `PanelView.swift`.

**The idea:** a weather report that says when it was measured and why a station is blank. "No reading since 2 PM: the station is offline" is trustworthy; a blank square is not.

## Work

- **The legend** (`LegendView.swift`). It opens from a "What the Icon Means…" item in the ••• menu, or a small ⓘ beside the summary. It has one line per badge, and says plainly that a plain cloud means "nothing needs you". Velum shows a plain cloud only when it has evidence; otherwise the panel says it can't tell (see the decision below).
- **A "why is it unknown?" line** under any account in `.unknown`. The provider gives the reason and what would end it, for example:
  - "No OneDrive report yet. The next is due by 2:45 PM."
  - "Velum may have missed changes between 1:10 and 1:25 PM (macOS dropped events). It will know again by 1:40 PM."
  - "OneDrive's report is 3 hours old."
  - A7's "OneDrive changed something Velum reads".

  The adapter returns the reason through C2's protocol; the view only shows it.
- **An age on every status.**
  - Each status shows how old its evidence is ("· 4 min ago"). Live sources say "live".
  - A report-based status older than the report interval plus 15 minutes is shown as old: secondary color and the word "old". It is never green, and it never counts as safe for the lid line.
- **VoiceOver** reads the same reasons and ages.

## Done when

- Tests cover:
  - every reason text, from made-up evidence;
  - the age wording;
  - the threshold for old evidence;
  - an old report never making the lid line safe.
- Screenshots in light and dark: the legend, an unknown account with its reason, a stale report.
- The panel's height still fits with two accounts unknown at once.

## Ownership and limits

You own:
- `LegendView.swift`;
- the age text in `AccountRow`;
- the reason strings in the OneDrive adapter;
- one ••• menu line in `PanelView.swift`.

Badge artwork stays as it is unless you decide otherwise (below).

## Decisions for the user

| Decision | Suggested |
|---|---|
| Should "unknown" get its own badge on the menu bar icon (it happens briefly after launch and during gaps) | No badge, but the panel's summary says Velum can't tell; revisit if it confuses |
| Where the legend opens from | The ••• menu, plus an ⓘ beside the summary |

## Hand-off

_Not started._
