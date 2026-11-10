# P3 · Google Drive, deep

**Bucket** P Providers · **Part two** · **Status: gated on a named maintainer** · **Waits for** C3, a named maintainer · **Runs alongside** P2 · **Feeds** nothing

## Brief

Google Drive for desktop has two modes:
- **Streaming,** which uses File Provider under `~/Library/CloudStorage`, so C3's generic tier covers it at basic fidelity.
- **Mirroring,** which keeps files in an ordinary folder with **no per-file sync flags** [S]. Velum can't see mirroring at all without Google Drive's own state.

The app probably draws one icon for up to four accounts [U]. The consultant rates this medium to large effort, and community-driven ([memo](../strategy-memo.md) §2, "Next", item 4; §6, risk 3).

Read the [campaign rules](../README.md#rules-every-card-follows), [G2's guide](G2-adapter-guide.md) and C3's hand-off.

**The idea:** the same as P2, with a harder house. Half of it (mirroring) has no windows to look through, so the person who lives there must show you the meters.

## Work

- **With the maintainer, first:** confirm the signals on their Mac. Candidates, all unverified [U]:
  - Google Drive's local state databases;
  - its accounts;
  - whether mirror mode exposes progress anywhere;
  - its icon's Accessibility text.
- **`Providers/GoogleDrive/`:**
  - streaming builds on the generic tier;
  - mirroring is covered only through confirmed signals, and stays `.unknown` without them, never "Up to date".
- **G2's live checklist** in both modes, on the maintainer's Mac.

## Done when

- The maintainer's checklist passes in both modes.
- Tests use synthetic fixtures.
- The maintainer is named in the README.

## Ownership and limits

You own `Providers/GoogleDrive/`. Without a maintainer, this card doesn't start.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Who maintains Google Drive | Nobody yet: leave it gated |

## Hand-off

_Not started._
