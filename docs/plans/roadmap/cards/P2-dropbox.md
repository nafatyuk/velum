# P2 · Dropbox, deep

**Bucket** P Providers · **Part two** · **Status: gated on a named tester** · **Waits for** C3, a named tester · **Runs alongside** P3 · **Feeds** nothing

## Brief

C3's generic tier gives Dropbox basic fidelity through its File Provider folder: waiting, uploading and failing. A deep adapter would add what only Dropbox knows:
- paused;
- the account's own status and errors;
- personal and business accounts;
- its actions.

The consultant's terms ([memo](../strategy-memo.md) §2, "Next", item 3; §6, risk 3): medium effort, and **only with a tester or contributor**, because nobody here uses Dropbox. An adapter for a client its maintainer doesn't use is how wrong statuses ship (risk 4).

Dropbox draws one menu bar icon [S], so the value here is "one light instead of N apps' icons", not merging accounts.

Read the [campaign rules](../README.md#rules-every-card-follows), [G2's guide](G2-adapter-guide.md) and C3's hand-off (what's unverified for Dropbox).

**The idea:** don't wire a house you've never been inside. Bring someone who lives there.

## Work

- **With the tester, first:** list Dropbox's signals on their Mac. Candidates, all unverified [U]:
  - the account information file in their home folder;
  - the process per account;
  - whether its icon's Accessibility text is readable;
  - which File Provider errors it gives.

  Keep only the signals the tester confirms.
- **`Providers/Dropbox/`:** discovery, the report, actions, and the generic tier's evidence underneath.
- **G2's live checklist,** run by the tester on their Mac, with results in the hand-off.

## Done when

- The tester's checklist passes on their Mac.
- Tests use synthetic fixtures shaped from their redacted captures.
- The tester agrees to be named as the maintainer.

## Ownership and limits

You own `Providers/Dropbox/`. Without a tester, this card doesn't start.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Who tests Dropbox | Nobody yet: leave it gated until a user volunteers (G3's first week) |

## Hand-off

_Not started._
