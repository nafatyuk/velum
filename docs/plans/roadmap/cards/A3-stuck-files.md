# A3 · Stuck files, by name

**Bucket** A Assurance · **Part one** · **Status: planned** · **Waits for** C2 · **Runs alongside** A4, A7, R2 · **Feeds** T1 (`velumctl pending`), S2

## Brief

`UploadTracker` already knows every file that hasn't reached the cloud: its path, account, when it changed, and whether it is waiting, uploading or failing, with OneDrive's reason. The panel shows only counts ("Waiting to upload 3"). The stuck alert says "3 files waiting since 2:14 PM" and names none of them. The consultant ranked a stuck-file detector second ([memo](../strategy-memo.md) §3, idea 2): files pending past a threshold, with Show in Finder. `oldestWaiting` exists already.

Read the [campaign rules](../README.md#rules-every-card-follows), [C1's](C1-permission-free-tracking.md#hand-off), [A2's](A2-problem-alerts.md#hand-off) and [C2's](C2-sync-provider-protocol.md#hand-off) hand-offs, `Sources/Velum/UploadTracker.swift` and `OneDriveControl.reveal` in `AppDelegate.swift`.

**The idea:** a lost-luggage desk. Not "3 bags are missing" but which bags, since when, and where they were last seen.

## Work

- **A listing method on the tracker,** for example `pending(olderThan:limit:)`. It returns the account, path, since, and state with any failure reason, oldest first, capped at 50. It reads what the tracker already holds, under its lock, with no extra File Provider calls.
- **A "Not in the cloud yet" section in the panel** (`StuckFilesView.swift`). It appears only when a file is past the threshold or failing.
  - Each row shows the file name, its account and folder, how long it has waited ("waiting 2 h") or the failure reason.
  - Show five rows, then "and N more".
  - Clicking a row shows the file in Finder.
  - Rows follow the panel's existing row style.
- **The stuck alert names a file:** "Report.docx and 2 more, waiting since 2:14 PM".
- **The threshold** is 10 minutes, the same as the stuck alert (your decision below). For tests, the defaults key `stuckAfterSeconds` overrides it.
- File names appear in the panel and the alert only. Never put them in logs.

## Done when

- Tests with a stand-in tracker cover:
  - the order;
  - the cap and "and N more";
  - the threshold;
  - failure reasons;
  - a file that changes again while listed (its newer change resets its clock).
- A live check on this Mac, with the user's yes for each step:
  1. Quit OneDrive.
  2. Write one probe file into the Personal OneDrive. With `stuckAfterSeconds` set to 30, it appears in the list, and Show in Finder selects it.
  3. Reopen OneDrive. The file leaves the list once it has uploaded.
  4. Delete the probe once it has settled.
- Screenshots of the section, light and dark.

## Ownership and limits

You own:
- the listing method on `UploadTracker`;
- `StuckFilesView.swift`;
- the stuck alert's text in `Notifier.swift`;
- one line in `PanelView.swift` that places the section.

No retry or "force upload" button: Velum observes.

## Decisions for the user

| Decision | Suggested |
|---|---|
| How long before a file counts as stuck | 10 minutes, the same as the stuck alert |

## Hand-off

_Not started._
