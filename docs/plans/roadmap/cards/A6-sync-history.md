# A6 · Sync history per account

**Bucket** A Assurance · **Part two** · **Status: planned** · **Waits for** C2 · **Runs alongside** P1, C3, T1, A5, S2 · **Feeds** S2

## Brief

The worst sync failure is the silent one: an account that stopped syncing days ago while every glance at the icon looked calm. Velum shows the present and a list of recent activity, but no shape over time. The consultant's seventh idea is a sync history sparkline per account, which "makes silent multi-day stalls visible" ([memo](../strategy-memo.md) §3, idea 7). The memo groups it with ideas 1, 2, 6 and 9 as the ones that move Velum "from icon tidier to sync assurance".

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off) and `AccountRow` in `PanelView.swift`.

**The idea:** a heart-rate trace instead of a single pulse check. A flat line with work waiting is the thing to notice.

## Work

- **`History.swift`:** one record per account per hour, holding:
  - uploads completed;
  - downloads;
  - the most files waiting;
  - failures;
  - whether coverage had a gap;
  - whether the status was unknown.

  Counts only, never file names. It is stored in `~/Library/Application Support/Velum/` and kept for 30 days (your decision).
- **Quiet and stalled are different.**
  - *Quiet:* nothing changed, nothing waiting. A quiet line is fine.
  - *Stalled:* files waiting and none uploaded. A stalled stretch stands out in the line and in the account's detail ("stalled for 2 days").
- **`SparklineView.swift`:** a small, plain sparkline in each account's row, or its detail line, covering the last 7 days. It has an accessible summary ("Uploads on 6 of the last 7 days; stalled since Tuesday").
- **No gaps invented.** Hours when Velum wasn't running show as unknown, not as quiet.

## Done when

- Tests cover:
  - bucketing by hour;
  - keeping 30 days;
  - quiet versus stalled;
  - hours when Velum wasn't running;
  - no file names stored (checked on the written file).
- History survives a restart.
- Screenshots of the row, light and dark, and with VoiceOver's summary.

## Ownership and limits

You own `History.swift`, `SparklineView.swift`, and one line in `AccountRow`. Draw with SwiftUI only. Keep the row's height.

## Decisions for the user

| Decision | Suggested |
|---|---|
| How much history to keep | 30 days, on this Mac only |

## Hand-off

_Not started._
