# A7 · Notice when a sync app changes underneath

**Bucket** A Assurance · **Part one** · **Status: done** November 13, 2026, for OneDrive, Google Drive and iCloud's `brctl` (merged into `main` at `f07c78d`) · **Waits for** C2 · **Runs alongside** A3, A4, R2 · **Feeds** S2, P4, A4

## Brief

The consultant's first risk is that OneDrive's internals change ([memo](../strategy-memo.md) §6, risk 1). Its answer:
- the generic tier as a floor (C3);
- provenance on every status (C1, C2);
- a tested-version note;
- degrading to `.unknown`.

This card is the tested-version note and the degrading.

Velum reads several OneDrive internals that Microsoft never promised to keep:
- the hourly `SyncDiagnostics.log` and its `SyncProgressState` codes (0 and 16777216 healthy, 65536 paused, 8194 not syncing, 1854 issue);
- the activity database `UXDatabase.db`: the columns of its `history_list` table, and its item types (4 downloaded, 5 uploaded, 6 deleted, 10 and 11 moved, 12 restored);
- the settings `.ini` files (`libraryScope` lines) used to find accounts;
- the process name;
- the icon's Accessibility text.

The README says "tested with OneDrive 26.204"; this Mac has 26.204.1019.

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off), the OneDrive adapter, and [A4's card](A4-legend-and-why-unknown.md) (it shows the reasons this card produces).

**The idea:** a canary. Before trusting the mine's air, check the bird. If OneDrive moved a wall, Velum stops reading behind it and says so, instead of reading the wrong room.

## Work

- **`Providers/OneDrive/Compatibility.swift`: one check per internal.** Each check answers fine, missing, or changed (unexpected columns, an unknown code, a file it can't parse). It runs:
  - at launch;
  - whenever OneDrive's version changes (`CFBundleShortVersionString` of the installed OneDrive app).
- **The tested versions** live in code, and the README carries one line about them.
- **A failed check drops that evidence; Velum never guesses.**
  - Statuses that depended on it become `.unknown`, with a reason A4 shows, such as "OneDrive 27.0 changed its activity database. Velum shows what macOS reports."
  - The activity list hides itself, with one line saying why.
  - One alert per new OneDrive version, through A2's notifier.
- **New values count as unknown, never healthy.** An unrecognized item type or `SyncProgressState` code reads as unknown, never as healthy, and it is recorded.
- **`--dump`** prints the check's results, and S2's report includes them.

## Done when

- Tests use synthetic fixtures built inside the test, never the user's real files:
  - an SQLite file with a renamed column;
  - a log with an unknown code;
  - a missing `.ini`;
  - a newer version string.

  Each one degrades exactly as described, and none ends in a green status or a safe lid line.
- On this Mac, read-only: `Velum --dump` shows every check passing for OneDrive 26.204.

## Ownership and limits

You own:
- `Providers/OneDrive/Compatibility.swift`;
- the adapter's calls into it;
- the README's tested-version line.

Never edit OneDrive's files. Never use `log show` (it returns nothing here).

## Hand-off

Built November 12–13, 2026, the night OneDrive updated itself from 26.204 to 26.212 at 11:28 PM and still read correctly. As the "What changed" note below asked, the card now covers Google Drive's internals and iCloud's `brctl` too, so its title changed from "Notice when OneDrive changes underneath" to **"Notice when a sync app changes underneath"**. The file name stays, so links keep working. The roadmap README's table row still uses the old title; the main session can update it at merge.

### How it works

- **Every read is checked, not only at launch.** The OneDrive and Google Drive readers already cached by file timestamp, so each check reruns when its file changes, plus at each discovery pass (every minute, and on force). A new client version clears the caches and checks everything again.
- **Five results per check:**
  - **ok**;
  - **missing**: not there yet, such as a new account's first report. Not a change;
  - **unrecognized**: a value Velum has never seen, such as a new status code. Recorded, and shown as unknown;
  - **unavailable**: can't be read right now, or not covered. Not a change;
  - **changed**: not in the tested shape, such as a missing line, column, table or tool, or an unparseable record.

  Only **changed** alerts. A locked database or a `brctl` timeout keeps the last result and never counts.
- **What a check that isn't ok does:**
  - the evidence that leaned on it is dropped, so the row goes unknown;
  - the row gets a reason, first in its notes line and in `AccountStatus.compatibilityNote` (for A4's reason line);
  - the lid stops saying "safe" when the lid relied on it;
  - the debug log (`[compat]`) and `Velum --dump` ("Compatibility:") say what moved.
- **The tested versions live in code:** `ProviderID.testedVersions` in `Providers/Compatibility.swift`, with OneDrive 26.204 and 26.212, Google Drive 133, and macOS 27.3. The README's Requirements carry the same three lines.
  - An untested version whose checks all pass changes nothing. It is only recorded ("not tested (tested: 26.204, 26.212) · every check that could run passes").
  - When a new version checks out, add it to both places.

| Service | Internal | When it isn't ok |
|---|---|---|
| OneDrive | settings `.ini` `libraryScope` lines | No account parses while live `OneDrive-*` folders exist, the standalone app is installed and its settings folder exists: each folder still shows as a row ("Found from its folder · Velum can’t read OneDrive 27.0’s settings"), with no status. Its uploads are tracked and it counts as running when OneDrive runs. Alerts |
| OneDrive | `SyncDiagnostics.log` `SyncProgressState` | Line missing: report dropped, "No status yet", alerts. Unknown code: "Status unknown", recorded, no alert |
| OneDrive | `UXDatabase.db` `history_list` columns | That account leaves Recent ("not shown in Recent"). Alerts |
| OneDrive | `history_list` item types and times | Unknown types leave Recent quietly (never "Synced"). Times that don't read as dates (e.g. milliseconds) alert |
| OneDrive | processes matched by open settings files | After a 2-minute grace (OneDrive relaunches after updating), every row says "Can’t tell whether OneDrive is running for this account". No lid block, no alert |
| OneDrive, Google Drive | every live `OneDrive-*` / Drive-linked root | A live root no row watches, for over 60 s, stops the lid ("Velum isn’t watching every OneDrive folder"). No alert |
| Google Drive | `GoogleDrive-<email>` naming | No folder found, but Drive's `my-drive` links point at live folders: those folders become rows. Alerts |
| Google Drive | DriveFS folder, each account's `my-drive` link | Queue and storage unavailable, lid blocked. Alerts. A new account gets 60 s for its link |
| Google Drive | `operations` table (the queue) | Changed: no status, lid blocked, alerts. Unreadable for over 10 s: the same without the alert ("right now · checking again") |
| Google Drive | `properties` → `driveway_account` | Recorded only, never a note or alert (storage is optional, and the sign-in fills in) |
| iCloud | `brctl status` | No container line, no `client:`/`server:` states, or `brctl` gone: the report is dropped, not kept from an earlier check. Alerts as "Velum can’t read part of iCloud on macOS 28.0" |
| iCloud | `brctl quota` | The "free" note is dropped. Recorded only |

### Decisions (Codex advised, the Fable consultant decided)

1. **An untested version alone changes nothing.** The checks decide, not the version list.
2. **The lid is blocked by dependency.** Only checks the lid relied on stop "safe": Google Drive's queue and account data, and live folders no row watches.
   - OneDrive's report, `brctl status` and the processes affect rows, not the lid, which rests on per-file flags.
   - Pending and failing files still come first on the lid.
   - This rewrites the Done-when's "none ends in … a safe lid line": a broken activity list can sit beside a green row that has its own evidence.
3. **Google Drive's queue: `runningReport` is retired.** "Up to date · Google Drive running" was a false green: deletes and renames would go unseen. Fable reversed its own P3 call. Two fixes stay in A7: failed queue reads are no longer cached until Drive next writes, and the same goes for OneDrive's log.
4. **The alert:**
   - only for a changed shape;
   - once per service and release (`26.212`, not each build), remembered across launches in `compatibilityAlerted`;
   - after the failure lasts 60 s;
   - no "resolved" note;
   - marked as told even with alerts off.
5. **Wording.** "Can’t read …", true whether the client changed or a file is damaged. The service comes first, then what still holds after the dot ("uploads are still tracked"), in secondary color. Every string is in `CompatibilityText`.

### Files

- New:
  - `Providers/Compatibility.swift`: the check types, versions, the SQLite schema reader, `UnwatchedRoots`, the alert latch and the strings;
  - `Providers/OneDrive/OneDriveCompatibility.swift`;
  - `Providers/GoogleDrive/GoogleDriveCompatibility.swift`;
  - `Providers/iCloud/ICloudCompatibility.swift`.

  Swift won't take two `Compatibility.swift` files in one module, hence the prefixed names (the README's ownership table says `Providers/OneDrive/Compatibility.swift`).
- Hooks, each on its own line:
  - each provider: one checker, its discovery result passed through, one `apply` before returning;
  - `Model.swift`: two fields, two copy lines, one lid line, placed just before the "may have missed changes" check;
  - `SyncProvider.swift`: two fields;
  - `Notifier.swift`: one property and one loop;
  - `Entry.swift`: the dump block.
- Google Drive provider: `runningReport` was removed, and relative `my-drive` links now resolve.
- iCloud provider: a changed shape clears the cached report or quota.
- README:
  - Requirements: the tested-versions lines;
  - "How Velum knows": the "When a sync app updates" paragraph;
  - Alerts: the new alert.

### Verified

- `Scripts/test.sh`: **113 tests pass.** That is 27 new in `CompatibilityTests.swift`, plus one Google Drive test rewritten for decision 3.
- Every fixture is synthetic and built in a temp folder:
  - an SQLite file with a renamed column;
  - a log with an unknown code, and one with no code line;
  - a missing `.ini`, plus signed-out, App Store and not-installed cases that must stay quiet;
  - a newer version string alone, and with a failure;
  - unknown item types and millisecond times;
  - unmatched processes;
  - an unwatched shared-library root;
  - an unreadable or renamed Google queue, a bad storage record, renamed Google folders found through relative and absolute links, and a new account's missing link;
  - changed and timed-out `brctl` answers;
  - the alert's once-per-release latch across a relaunch, and with alerts off;
  - the lid's order.
- **On this Mac, read-only** (`build/Velum.app/Contents/MacOS/Velum --dump`, November 13, 12:19 AM): every check passes for OneDrive 26.212 (26.212.1029), Google Drive 133 (133.0) and macOS 27.3. The leftover `OneDrive-SharedLibraries-…` and dated folders don't read as live, so the lid isn't blocked. The debug log wrote the three `[compat]` headlines.
  - Around midnight OneDrive's main app stopped for a while, leaving only its Sync Service helper, and the processes check rightly didn't run. Once OneDrive was running again (not started by this session), the final dump showed that check passing too.
- A rendered panel with made-up data (light and dark): unknown rows with their reasons, a green row beside them, and the lid's "Velum can’t read Google Drive’s queue."

### Left out, and follow-ups (Fable's order)

1. **`UploadTracker` starts a new account at the current event** without checking files already pending, which can give a false "safe" (Codex's catch).
2. **OneDrive's icon text outranks live failures** in `Collector.status`: a row can read "Up to date" while the lid says files can't upload.
3. **Synced SharePoint libraries** (`OneDrive-SharedLibraries-*`) are their own File Provider roots, which no row watches. If one is live, the lid now says "Velum isn’t watching every OneDrive folder", which is true. Add those roots to their account's `watchRoots`.
4. **The App Store OneDrive** (`com.microsoft.OneDrive-mac`, settings inside its container) isn't supported. A7 is careful not to alert for it.
5. Smaller:
   - OneDrive's activity cache still keeps an empty list after a failed read until the database changes, which it does often;
   - the icon's Accessibility text is not checked here (P4 owns its classification; unknown wording already reads as unknown);
   - with both a reason and storage, a Google row's notes line can cut off the storage figure until A4's reason line takes the reason.

### For other cards

- **A4:** show `AccountStatus.compatibilityNote` in the "why unknown?" line, in place of a generic "No report yet" (the report was dropped on purpose). Then remove the notes insert in `CompatibilityReport.record` (one loop). "Google Drive running" no longer exists, so the legend shouldn't explain it. An unreadable queue now reads "No status yet".
- **S2:** include `CompatibilityReport.dumpLines`. Account names and emails appear there as elsewhere in the dump. Drive's numeric account ID is deliberately never printed.
- **The main session at merge:** A4 may also add a line near `Snapshot.lidVerdict`'s end, and A3 may touch the Alerts list in the README; both are separate lines from A7's.

### What changed since this card was written (November 12)

- **Google Drive's internals need the same canary.** Velum now also relies on:
  - the `operations` table and the `driveway_account` record in each account's `metadata_sqlite_db`;
  - the `my-drive` symlink that maps a DriveFS folder to an email;
  - the `user-paused` file;
  - the `GoogleDrive-<email>` folder naming.
- **Two of them already fail safe.** Storage shows only if limit − used = remaining. An unreadable queue falls back to "Google Drive running", never to a false "Up to date".
- **The rest of this card's pattern still applies:** a per-version check, a reason line, and one alert per new version. iCloud's `brctl` output belongs here too.
