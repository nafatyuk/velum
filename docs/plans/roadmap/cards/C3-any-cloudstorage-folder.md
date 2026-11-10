# C3 · Any CloudStorage folder (beta)

**Bucket** C Core · **Part two** · **Status: planned** · **Waits for** C2 · **Runs alongside** P1, T1, A5, A6, S2 · **Feeds** S1, G2, P2, P3

## Brief

Every sync client built on Apple's File Provider puts its folders under `~/Library/CloudStorage`: Dropbox, Google Drive in streaming mode, Box, Proton Drive, Nextcloud and others [S]. The same per-file flags, FSEvents and transfer progress that Velum uses for OneDrive work for all of them, with no knowledge of the client. The consultant calls this the generic tier ([memo](../strategy-memo.md) §2, "Architecture" and "Next", item 2). It serves two purposes:
- it is the basic fidelity for any client;
- it is the floor if OneDrive's internals change (risk 1).

Two cautions:
- **Untested here.** This Mac has only OneDrive, so the tier is labelled beta until P2 and P3's testers check it against real clients (risk 4: a false "synced" in a client nobody here uses).
- **Leftover folders.** This Mac has two leftover folders in `~/Library/CloudStorage` whose names end with a date in parentheses. They belong to File Provider domains that were removed. The tier must ignore folders like these.

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off), and [P1's card](P1-icloud-drive.md) (the closest worked example).

**The idea:** a universal adapter, the kind travellers carry. It doesn't know the country; it fits any socket built to the international standard, and that's enough to charge a phone.

## Work

- **Discovery** (`Providers/Generic/`):
  - Every folder under `~/Library/CloudStorage` that a live File Provider domain owns.
  - Skip the folders an adapter already claims (OneDrive's go to the OneDrive adapter).
  - Find a check that tells a live root from a leftover, verified on this Mac's two leftovers. Candidates: whether the root reads as ubiquitous; File Provider resource values on the root. Record which one works.
  - Display names from the folder name, for example "GoogleDrive-<email>" becomes "Google Drive". Show the email only in the account detail, and redact it in S2's report.
- **Fidelity:** waiting, uploading, failing with the reason, and downloads.
  - There is no report and no Accessibility text.
  - The tier makes no "not running" claim unless it can tell which process owns the folder.
  - When the evidence runs out, the status is `.unknown`, never healthy.
- **Labelled beta** in the row and in `--dump`, for every folder.
- **A cross-check,** since OneDrive is the only client here: a test-only switch runs OneDrive's folders through the generic tier and compares the pending counts with the OneDrive adapter's, live.

## Done when

- Tests with a made-up folder tree cover: live roots and leftovers, adapter-claimed folders skipped, display names.
- The live cross-check on this Mac agrees with the OneDrive adapter through one probe file's life (with the user's yes; the probe is deleted afterwards).
- The leftover folders on this Mac don't appear.
- The hand-off lists what is unverified for each client, for P2 and P3's testers.

## Ownership and limits

You own `Providers/Generic/`, root discovery and their tests. Never open, write or rename anything inside another client's folder beyond reading per-file flags.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Show generic folders by default, or behind a switch | Shown, each labelled beta |

## Hand-off

_Not started._
