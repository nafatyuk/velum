# A3 · Stuck files, by name

**Bucket** A Assurance · **Part one** · **Status: done** November 13, 2026 (branch `claude/a3-stuck-files-647652`) · **Waits for** C2 · **Runs alongside** A4, A7, R2 · **Feeds** T1 (`velumctl pending`), S2

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

Built November 12–13, 2026, in a worktree session running alongside A4 and A7.

**The listing** (`UploadTracker.swift`):
- `pending(olderThan:limit:now:) -> PendingList`. A file qualifies when its latest change is at least `olderThan` old, or when its upload is failing, at any age.
- `PendingFile` carries `account` (the key), `path`, `since` (its latest change) and `status`: `.waiting`, `.uploading`, or `.failed(reason)`. The reason is macOS's text without the "name: " prefix the tracker stores. "Unchecked" files (the service hasn't said yet) count as waiting, the same as the account row's count.
- The order is **failing first, then oldest first**, sorted before the cap of 50. This departs from the card's "oldest first", on the consultant's call: failing files are the only ones the user can act on, and strict age order could push them past row five.
- `PendingList` also carries `total` and `perAccount`, so "and N more" and the alert's count stay right past the cap.
- It reads the tracker's own dictionary under its lock and asks File Provider nothing.
- `UploadTracker.stuckAfter`: 10 minutes; the defaults key `stuckAfterSeconds` overrides it. The Notifier now reads the same value for its stuck check (and Google Drive's "changes are stuck").
- **Behavior change:** a newer change restarts a file's clock (`since` is reset on every created, modified or renamed event). Before, the first change's time stuck. So "stuck" means the latest version has waited, and a file someone keeps editing isn't reported as stuck. This also moves the account row's "waiting since" and the stuck alert, consistently.
- `init(defaults:)` and an internal `record(...)` let tests run a stand-in tracker in a throwaway defaults suite; `State` and `Candidate` are internal for the same reason. The saved format is unchanged.

**The section** (`StuckFilesView.swift`, one line in `PanelView.swift`):
- **Placement:** the top of the scrolling body, right under the lid line, so it names the files the lid line only counts. It shows only while a file qualifies, so a clean panel looks as before.
- **Heading:** "Not in the cloud yet", with the total in the heading's tertiary style ("7 files").
- **Rows:** Recent's shape (type icon, name with middle truncation, one subtitle).
  - "Waiting 12 min" / "Waiting 2 hr" / "Waiting 3 days" / "Waiting since Nov 3" after a week.
  - "Uploading · changed 25 min ago". Velum knows when the file changed, not when its upload started.
  - "Can’t upload" in orange, with macOS's reason verbatim on its own wrapping line, and the icon top-aligned.
  - When the service's app is stopped: "Can’t upload · OneDrive isn’t running". The live check showed why: with OneDrive quit, macOS reports a new file as failing with "Your device couldn’t connect to the server…".
  - The account is added last (" · Personal"), only when there's more than one account, and is what truncates.
  - The folder ("In Documents/Taxes") and the change time are in the hover help.
- Clicking a row shows the file in Finder through the existing `reveal`, falling back to the nearest folder if the file is gone.
- **More than five:** five rows, then "Show N more" (lined up with the file names), which expands to the 50 listed. Past the cap, the expanded list ends with "and N more not listed". "Show fewer" collapses it. It also collapses when the panel resigns key (closes) and when five or fewer are left.
- **Ages:** a `TimelineView` re-renders them every 30 s.
- **VoiceOver:** one element per row, saying what the row truncates or hides. For example: "Report.docx, waiting 2 hours, OneDrive, Personal, In Documents/Taxes", with the hint "Shows the file in Finder". The heading has the header trait.

**The alert** (`Notifier.swift`):
- The title is unchanged ("<account>: uploads are stuck").
- The body names the account's oldest waiting file: "Report.docx and 2 more, waiting since 2:14 PM." or "Report.docx has been waiting since 2:14 PM.". "Since" carries a date when the wait began before today ("Nov 9, 2:14 PM").
- It counts only the account's files past the threshold, not younger ones still on their way.
- Names longer than 40 characters lose their middle, keeping the extension, so Velum's own three-line banner still shows the time.
- With no listed file to name, it falls back to the old count wording.
- **File names stay out of the debug log:** `Problem.logged` gives `post` a name-free twin ("3 files waiting since 2:14 PM") to log instead of the body.

**Look and wording:** Codex and the Fable consultant answered the same brief separately. They agreed on placement, heading, row shape, age wording and listing uploading files. Fable decided the conflicts:
- the account only with several accounts;
- the reason on its own line with no icon badge;
- failing first;
- "Show N more";
- the alert keeps "stuck" and the card's wording, with Codex's counting;
- "Waiting" for unchecked files;
- the stopped-app wording.

**Tests:** `StuckFilesTests.swift`, 19 new, 105 in all, with made-up paths under `/Users/test`. They cover:
- the threshold and its edge, and the `stuckAfterSeconds` override;
- failing-first then oldest-first order;
- the cap of 50 with its totals;
- reasons losing the file name;
- states and fields;
- a newer change restarting the clock (through `record`);
- a gone file leaving at the next check;
- five rows, "Show N more" and "not listed" past the cap;
- every subtitle, the stopped-app wording and VoiceOver strings;
- the alert body for one file, several, another account's files, earlier days and long names, and that its logged twin names no file.

**Tools:**
- `Velum --dump` prints a "Not in the cloud yet" block.
- `Velum --render-panel out.png --sample-stuck` fills the section with seven made-up files across the live accounts, to look at it without real stuck files. The account names in such a render are real, so keep it out of the repo.

**Live check, November 13, with the owner's yes** (screenshots kept in the session's scratchpad, not the repo):
1. Set `stuckAfterSeconds` to 30 and quit OneDrive (it took two quit requests to stop both of its processes).
2. Wrote `velum-test-<time>.txt` at the top of the Personal OneDrive at 00:16:06.
   - `Velum --dump` listed it under "Not in the cloud yet". It was listed as **failing**, not waiting: with OneDrive quit, File Provider reports the new file as `uploaded=false, uploading=true` with an upload error, "Your device couldn’t connect to the server…". That's what led to the "OneDrive isn’t running" wording.
   - The installed Velum was quit for a few minutes and this branch's build opened in its place; nothing was installed.
   - The owner opened the panel and saw the row as "Can’t upload · OneDrive isn’t running", with macOS's reason below. They clicked it, and Finder opened with the file selected. Finder's selection, read back with AppleScript, was the probe's path.
3. Reopened OneDrive at 00:23:52. The file's flag turned `uploaded=true` at 00:24:07. `--dump` then listed nothing under "Not in the cloud yet", and Recent showed "Uploaded just now".
4. Deleted the probe at 00:25:27, 80 s after it uploaded. It was still gone 20 s and a minute later.

Afterwards: the test key was removed, the branch build quit, and the installed Velum reopened.

Not checked live:
- **The named alert itself.** Per-account alerts are held back while OneDrive is stopped, and a running OneDrive uploaded the probe within seconds, so it never sat waiting for the threshold. The alert's wording is covered by the tests.
- **"Show N more" and the collapse on close.** There was only one stuck file. They're covered by the tests and the made-up render.

Section screenshots, light and dark, come from `--render-panel --sample-stuck` with made-up files.

**Left out, or for later cards:**
- **`DebugLog.changes` already logs `firstFailure`**, a failing file's name, which DebugLog's header documents as allowed. The campaign rule says file names never go to logs. A3 adds no new names to the log; whether to redact that existing line is the owner's call, on S2 or a small card of its own.
- **`--render-panel` can't draw the panel's top while a service is stopped.** With OneDrive quit, everything above the heading's glass Start button renders blank, in `main`'s build too. It looks like a limit of `cacheDisplay` with glass buttons.
- **The account row's "waiting since" line** still uses a fixed 10 minutes rather than `stuckAfter`; it's A4's age text.
- **For T1:** `velumctl pending` can call `pending(olderThan: 0)` for everything not yet in the cloud, failing first.
- **For S2:** the section and the alert carry file names, so the redacted report must cover `Snapshot.stuck`.
- **For merging:** the edits to shared files are on their own lines:
  - `Model.swift`: one `Snapshot` field, and two lines in `Store.refresh`.
  - `PanelView.swift`: one line.
  - `Notifier.swift`: the `Problem.logged` field, `stuckAfter` reading `UploadTracker.stuckAfter`, the stuck problem, `post`'s `logged:` parameter, and three static helpers at the end.
  - `Entry.swift`: the dump block and `--sample-stuck`.
