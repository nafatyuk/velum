# G2 · An adapter guide

**Bucket** G Going public · **Part two** · **Status: planned** · **Waits for** C3, P1 · **Runs alongside** S1, R3 · **Feeds** G3, P2, P3

## Brief

You use OneDrive and iCloud. Dropbox, Google Drive, Box and the rest need people who use them. The consultant's answer is to make provider adapters the unit of contribution: publish the protocol and an adapter guide ([memo](../strategy-memo.md) §5, item 9). A deep adapter also needs a named maintainer (§6, risk 3). By the time this card starts there are three worked examples: OneDrive (C2), iCloud (P1) and the generic tier (C3).

Read the [campaign rules](../README.md#rules-every-card-follows) and the hand-offs of C1, C2, C3, P1, A4 and A7.

**The idea:** a recipe card for a dish you won't cook yourself. It has to work for a stranger in a different kitchen.

## Work

`docs/adapters.md`, linked from the README and a short `CONTRIBUTING.md`, covers:
- **What an adapter answers:** the protocol's methods, each with what it means and what to return when you can't tell.
- **The trust rules:**
  - never assume OK;
  - every status gets a source and an age;
  - output the adapter doesn't recognize counts as unknown;
  - a client that changes underneath (A7's pattern).
- **The three examples:** what each reads, and why.
- **Testing without anyone's data:** synthetic fixtures, and redacted captures (S2).
- **The live checklist** every adapter passes on a real Mac:
  1. A probe file goes waiting → uploading → uploaded.
  2. A failing upload.
  3. The client quit.
  4. The client restarted with its icons hidden.
  5. Offline.
  6. The lid line's verdict at each step.
  7. Probes cleaned up.
- **Maintainers:** a deep adapter needs a named maintainer who uses the client; without one it stays in the generic tier.
- **The pull-request checklist.**

## Done when

- **A dry run:** a fresh agent session, given only the guide and the repo, sketches a Dropbox adapter skeleton that compiles against the protocol. The sketch is thrown away, never committed. The session reports what the guide didn't answer, and those gaps are fixed.
- The checklist matches what P1 actually did.

## Ownership and limits

You own `docs/adapters.md` and `CONTRIBUTING.md`. Write no adapter code.

## Hand-off

_Not started._
