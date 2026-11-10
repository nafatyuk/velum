# A1 · "Safe to close the lid?"

**Bucket** A Assurance · **Part one** · **Status: done** November 10, 2026 (`d09e180`) · **Waits for** C1 · **Runs alongside** A2 · **Feeds** A5, T1

## Brief

The consultant ranked this the most valuable feature for its effort ([memo](../strategy-memo.md) §3, idea 1): one line at the top of the panel saying whether every change on this Mac has reached the cloud.

Read the [campaign rules](../README.md#rules-every-card-follows) and [C1's hand-off](C1-permission-free-tracking.md#hand-off).

**The idea:** the question you actually have when you pick up the laptop, answered in one line.

## Work

- Work out one verdict from every account's live upload tracking. Never use OneDrive's hourly report for it: a "healthy" report can sit beside a file still waiting to go up.
- Show the verdict as the first row of the panel.

## Done when

The line reads correctly for every verdict, live on this Mac.

## Ownership and limits

`LidVerdict` and `Store.lidVerdict` in `Model.swift`; `LidRow` in `PanelView.swift`.

## Hand-off

`Store.lidVerdict` checks, in order:
1. OneDrive, or any account, not running → `.notRunning`;
2. no accounts → `.unknown("No OneDrive accounts found")`;
3. any failed uploads → `.failing(n)`;
4. any pending uploads → `.pending(n)`;
5. an account whose tracker may have missed changes → `.unknown("Velum may have missed recent changes in <account>")`;
6. otherwise `.safe`.

`LidRow` shows each verdict as:

| Verdict | Symbol | Headline | Example detail |
|---|---|---|---|
| Safe | green laptop | "Safe to close the lid" | "Every change on this Mac is in the cloud" |
| Pending | blue arrow | "Wait before closing the lid" | "3 files still on the way up" |
| Failing, or not running | orange | "Not everything is in the cloud" | |
| Unknown | | "Can't vouch for every change" | the reason |

**For later cards:**
- T1's `velumctl lid` and A5's sleep guard read this same verdict.
- Once more providers exist (C2, P1, C3), the verdict covers every provider's folders.
- An account in a generic-tier folder that can't vouch must make the whole verdict unknown, never safe.
