# C1 · Permission-free tracking as the product

**Bucket** C Core · **Part one** · **Status: done** November 10, 2026 (`0a85400`) · **Waits for** nothing · **Runs alongside** nothing · **Feeds** A1, A2, C2

## Brief

Velum first read each account's status from the text of OneDrive's own menu bar icons, through Accessibility. That stops working once OneDrive launches while its icons are hidden (System Settings → Menu Bar → Allow in the Menu Bar, off), which is exactly how Velum is meant to be used. The consultant's first "Now" item was to make the permission-free signals the product, and Accessibility an optional extra ([memo](../strategy-memo.md) §2, "Now", row 1).

Read the [campaign rules](../README.md#rules-every-card-follows).

**The idea:** ask macOS, not OneDrive's icon. macOS keeps its own per-file record of what has reached the cloud, and anyone may read it.

## Work

- Watch each account's folder for changed files (FSEvents) and ask File Provider where each one is (`ubiquitousItemIsUploaded`, `…IsUploading`, `…UploadingError`, `…IsExcludedFromSync`).
- Count transfers from File Provider's progress on each folder root.
- Fill in account-wide state from OneDrive's hourly `SyncDiagnostics.log` and its activity database, with their times.
- Add an honest "unknown" state. Give every status a source label. Never say "Up to date" without evidence.
- Keep Accessibility as an opt-in extra ("Show OneDrive's Exact Status…").

## Done when

- Status survives OneDrive restarting with its icons hidden.
- Probe files in the Personal OneDrive (created and deleted with the user's yes) show waiting → uploading → uploaded.
- With no evidence, Velum says so instead of "Up to date".

## Ownership and limits

`UploadTracker.swift`, `TransferMonitor.swift`, the status merge in `Model.swift`, the panel's source labels.

## Hand-off

Built and verified live November 10, 2026, with probe files in the Personal OneDrive (always deleted afterwards).

**`UploadTracker`** (`Sources/Velum/UploadTracker.swift`):
- **Watching.** One FSEvents stream per account folder, with file events, no defer, watch root, and 0.5 s latency.
- **What it keeps.** Each changed file becomes a candidate: account, since, a generation (bumped on every change, so a check never erases newer work), state (unchecked, waiting, uploading, or failed with a reason), and when it was last checked.
- **Saved across restarts.**
  - The candidates are saved as JSON in the defaults key `pendingUploads`.
  - The resume point is saved per account in `fseventsLastID.<account>` and `fseventsLastTime.<account>`. The start ID is taken before the stream is created.
  - A resume point is replayed only if it is less than 24 hours old; otherwise the account is marked as having a gap.
  - The resume point is refreshed every 10 minutes using the ID from the previous interval.
- **Gaps.** Lost-event flags mark the account as having a gap for 15 minutes (`coverageGap`). While the gap lasts, "nothing pending" isn't proof.
- **Checking.** `summary()` checks at most 400 candidates per pass, oldest checked first. `inspect()` returns nil (done with this file) when it is gone, excluded or uploaded.
- **Filter.** `isSyncable` skips `.DS_Store`, `Icon\r`, `._*`, `~$*`, `.fetch` and `.tmp`. `.fetch` is OneDrive's; C2 moves it into the OneDrive adapter.

**`TransferMonitor`:**
- It subscribes to `Progress` at each folder root. Downloads carry a file operation kind.
- OneDrive's uploads arrive with no kind, two per file. They are counted as "other" and shown as "Syncing changes" with no number, because a number would be double.
- A transfer counts as stalled after 120 s with no movement. Movement is recorded before stalled entries are filtered out.

**`Collector.status` order**, which C2 turns into the rule for every adapter:
1. client not running;
2. live Accessibility text ("From OneDrive");
3. failed uploads (`.error`, "Live from macOS");
4. files moving ("Uploading/Downloading/Syncing N files");
5. files waiting ("Waiting to upload N", or "Paused, N waiting");
6. progress with no label ("Syncing changes");
7. the report's codes.

A healthy report gives "Up to date". Its source reads "Nothing pending · OneDrive report, <time>" when the tracker has no gaps, or just the report's time otherwise. With no evidence at all, the status is "No status yet" or "Status unknown".

**Known limits, for later cards:**
- Pause and sync-issue states lag by up to an hour, because OneDrive writes its report hourly (A4 shows the age).
- A folder rename with files still pending inside it.
- Accessibility text is read in English only (P4).
