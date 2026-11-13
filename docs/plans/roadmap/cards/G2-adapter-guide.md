# G2 · An adapter guide

**Bucket** G Going public · **Part two** · **Status: planned** · **Waits for** P1, P3 (both done; C3 optional) · **Runs alongside** S1, R3 · **Feeds** G3, P2, P3

## Brief

You use OneDrive, iCloud Drive and Google Drive, and all three have adapters. Dropbox, Box and the rest need people who use them. The consultant's answer is to make provider adapters the unit of contribution: publish the protocol and an adapter guide ([memo](../strategy-memo.md) §5, item 9). A deep adapter also needs a named maintainer (§6, risk 3). There are three worked examples already: OneDrive (C2), iCloud Drive (P1) and Google Drive (P3, built November 12), and C3's generic tier adds a fourth if it lands first.

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

### What changed since this card was written (November 12)

- **Ready to start.** The three adapters show the full range:
  - a client with its own reports and Accessibility text (OneDrive);
  - a system service with no client and a slow command-line check (iCloud, `brctl`);
  - a client with a readable local queue and cached account record (Google Drive).
- **Patterns the guide should teach:**
  - `isLiveCloudFolder` for discovery: leftover folders answer "no value", so only a clear yes counts;
  - live evidence before reports;
  - a service is present only with a live account;
  - `clientBundleID` for Start, Restart and Quit;
  - `deletedFilesLabel`;
  - optional data, like storage, never changes a row's state, the lid line or the icon;
  - undocumented formats are trusted only through a self-check, like Google storage's limit − used = remaining.
