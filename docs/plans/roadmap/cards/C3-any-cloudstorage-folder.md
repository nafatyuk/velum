# C3 · Any CloudStorage folder (beta)

**Bucket** C Core · **Part two** · **Status: done** (November 13, overnight; not merged) · **Waits for** C2 · **Runs alongside** P1, T1, A5, A6, S2 · **Feeds** S1, G2, P2, P3

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

**Done** November 13, 2026, overnight, in its own worktree (not merged).

### What was built

- **`Providers/Generic/GenericProvider.swift`**, the generic tier. Every folder in `~/Library/CloudStorage` that `isLiveCloudFolder` calls live (a clear yes only; on a hiccup a known folder stays, a new one waits) and that no deep adapter claims becomes one row under a new heading, **Other Cloud Folders** (`ProviderID.cloudStorage`, raw value `cloudstorage`, key `cloudstorage:<folder name>`). It reads nothing of the client's own: rows get files waiting, uploading, failing (with macOS's reason) and downloading from the shared `UploadTracker` and `TransferMonitor`, exactly as every service does. `clientRunning` is `nil` and `running` stays `true`: no "not running" claim, ever. No Start, Restart or Quit.
- **Claims** (`ProviderID.claims(folder:extensionID:)`): a deep adapter owns a folder by its name (`OneDrive-*`, `GoogleDrive-*`) or by the File Provider extension behind it (`com.microsoft.OneDrive…`, `com.google.drivefs…`, `com.apple.CloudDocs…` for iCloud), so a renamed folder can't show twice. New deep adapters add their claim there; the guide says so.
- **Which app.** Every live root here carries the extended attribute `com.apple.file-provider-domain-id`, "<extension bundle ID>/<domain ID>"; the two leftovers carry none. Velum takes the extension's ID, tries its shorter prefixes as app bundle IDs through Launch Services, and accepts an app only if its `Contents/PlugIns` (or `Contents/Extensions`) really ships an extension with exactly that ID. The row is then named as the app names itself ("Dropbox"). Otherwise the name is the folder's own spelling before the first hyphen, and the notes line says "app unknown". The domain's own ID (Google Drive's is the account number) is never shown or logged.
- **Names.** The app's name; where two rows would share it, "Dropbox (Work)", an address shortened to its part before the @ unless that clashes too. The folder's account part ("Personal", an address) otherwise goes on the notes line only, as the card asks.
- **Beta, on every row and in `--dump`.** The notes line starts "Beta" ("Beta · Personal", "Beta · app unknown · …"), with hover help; the heading's trailing text counts folders. `--dump` prints a service line ("Other Cloud Folders (beta): 2 folders · macOS’s file flags and transfer progress only · the lid can’t say safe") and, under each row, which app and how Velum knows.
- **••• → Show Other Cloud Folders** (`OtherCloudFoldersToggle.swift`, defaults key `showOtherCloudFolders`, on by default). Off, the tier isn't discovered or watched at all. The item shows only while the tier has folders, or while it is off.
- **`Velum --cross-check [seconds]`** (`GenericCrossCheck.swift`, test-only): runs OneDrive's and Google Drive's folders through the generic tier as well, each side with its own throwaway saved state, and prints both views' waiting, uploading and failing counts every 5 s, plus the app the generic tier identifies for each folder.
- **Small shared edits**, each on its own lines: the `ProviderID` case and an optional `webURL` (`nil` hides View Online) in `SyncProvider.swift`, plus `AccountEvidence.unknownHeadline`; in `Model.swift` the provider in `Collector`'s list (last), one lid line, one headline line, one ternary for the follow-up sentence; `PanelView.swift` (globe and View Online only with a web address, the toggle, the heading's count, the empty-panel sentence); `LegendView.swift`, `Entry.swift`, `Diagnostics.swift`, `Compatibility.swift` (`testedVersions` is macOS 27.3: no client was tested), `SleepGuard.swift` (one line, below), `SampleData.swift` (`--sample beta`), `Scripts/check-redaction.py` (the account part of any other CloudStorage folder, and any address in it).
- **Docs:** `docs/adapters.md` (the C3 exception to "confirm the flags first", `unknownHeadline`, optional `webURL`, the domain attribute, claiming your folders, a section on the generic tier, the maintainers table, the file-by-file table now has nine switches), `docs/velumctl.md` (the `cloudstorage` id and keys; exit 3 while a beta folder is shown), `README.md`.

### Never a false "synced": the answer

- **The row.** A generic account has no report, and C1's merge (`Collector.status`) gives `.ok` only through a report: with no live work and no report it ends `.unknown`. So a generic row can never be "Up to date", by construction, not by a special case. It reads "Can’t tell" (no "yet": nothing would end the doubt), "Velum sees only macOS’s file flags here, not Dropbox’s own status.", and, when Velum's tracking has no gaps, "macOS shows nothing waiting to upload." (the source says it, rather than Velum's own "Nothing is waiting to upload."). A4's reasons and the menu bar are unchanged: `.unknown` and `.ok` draw the same plain cloud, so a Dropbox user gets no permanent badge.
- **The lid.** The campaign rules and C1's order would let the lid say "Safe" from flags alone, and the adapter guide forbids exactly that for unconfirmed flags. So generic folders feed the lid's "wait" and "not everything is in the cloud" (their waiting and failing files count), but while one is shown and nothing else stops the lid, it says "Can’t vouch for every change · Velum hasn’t been tested with Dropbox (beta)." Both consultants agreed. `velumctl lid` exits 3 then, never 0; `docs/velumctl.md` says to handle 3 apart from 1. Turning the tier off gives the lid back to the other services.

### Decisions

| Decision | Made | Codex | Fable (rules conflicts) |
|---|---|---|---|
| Show the tier by default, or behind a switch | **Shown, each labelled beta.** Decided overnight by the supervisor, the owner's to reverse (one line: `GenericProvider.isShown`'s default) | — | — |
| May beta folders make the lid "Safe"? | **No**; their work still counts | No: a beta label can't substantiate "Every change … is in the cloud" | No: "a wrong 'wait' costs a minute; a wrong 'safe' costs a file" |
| An escape hatch | **••• → Show Other Cloud Folders**, global | not raised | Yes, in this card; off means fully unwatched |
| Heading | **Other Cloud Folders**, trailing "1 folder"/"N folders" | this | ruled for Codex ("folders" is what the rows are) |
| Row name and clashes | **App name; "Dropbox (Work)" on a clash; an address as its part before the @** | clash label only when not an email; email in the alert body | ruled: local part, keeps Notifier untouched |
| Where "beta" goes | **First on the notes line** | same | same; a name suffix would leak into alert titles |
| Unnamed client | **Folder spelling, "Beta · app unknown"** | "app unknown" | ruled for Codex |
| Idle headline and reason | **"Can’t tell"; "Velum sees only macOS’s file flags here, not X’s own status."; "macOS shows nothing waiting to upload."** | keep "Can’t tell yet"; "Check Dropbox for its full status" | ruled: no "yet"; its reason; the follow-up names macOS |
| Lid sentence | **"Velum hasn’t been tested with Dropbox (beta)"**, "… Dropbox or Box …", "… 3 cloud folders’ apps …" (also whenever an app is unknown) | this form | ruled for Codex's form, "or" as in `Reasons.cantTell`, count form for 3+ or unknown |
| Hover help | **Codex's, plus "The lid line won’t say “Safe” while this folder is shown."** | — | ruled |
| Legend | **First line now "The lid line trusts only live evidence, never a periodic report."; a line for the tier** | wanted the first line changed | worded both |
| Empty panel | **"… Other cloud folders show up too, in beta."** | two sentences | ruled |
| "Resolved" alert wording for generic rows | **Left alone** (shared text, Notifier untouched) | wanted "macOS no longer reports…" | follow-up, once testers report |
| Shut-down note naming "Other Cloud Folders" as an app | **Fixed:** services with no app of their own read "after you log in again", as iCloud already did | — | — |
| Live versus leftover | **`isLiveCloudFolder`, a clear yes** (the card's update); the domain attribute also separates them here, recorded but used only for naming | — | — |

### Checked

- **Tests:** `Scripts/test.sh` through the shared queue, twice: 254 tests in 51 suites pass, 28 of them new (`GenericTests.swift`: live roots and leftovers, claimed folders skipped by name and by extension, a hiccup keeps a known folder and adds none, not present without CloudStorage or when switched off, display names and clashes, "app unknown", the domain attribute and extension parsing, an app found only by the extension it ships, the merge never "Up to date", live work as for every service, the lid's sentences, pending and failing still counting, redaction names, the legend, the sample panel; plus one in `SleepGuardTests.swift`). Plain temporary folders go through the real `isLiveCloudFolder`, no seam. `./build.sh` built.
- **Live, this Mac, `build/Velum.app/Contents/MacOS/Velum --dump`:** exactly the same services and accounts as main's build just before (OneDrive with two accounts, iCloud Drive, one Google Drive account), with the same keys and states; no "Other Cloud Folders" line, no generic row, no "beta" anywhere. The two dated OneDrive leftovers don't appear.
- **Live cross-check, `Velum --cross-check 20`** (no probe file): all three live CloudStorage folders were found by both a deep adapter and the generic tier, none by the generic tier alone, so the leftovers stayed out of the generic path too. The generic tier identified each app from its folder's File Provider extension: OneDrive (`com.microsoft.OneDrive`, extension `com.microsoft.OneDrive.FileProvider`) for both OneDrive folders, Google Drive (`com.google.drivefs`, `com.google.drivefs.fpext`). Waiting, uploading and failing agreed at every sample (all idle). The first run left its two throwaway preference files behind; fixed, the files deleted, and the second run left none.
- **`Scripts/check-redaction.py`** against the new build: nothing personal found (149 strings looked for). It now also treats the account part of any other CloudStorage folder, and any address in it, as personal.
- **The panel, made-up data:** `Velum --render-panel out.png --sample beta` (light, dark, legend) shows "Other Cloud Folders · 2 folders", a grey "Dropbox · Can’t tell" row with its reason and "Beta", an "AcmeSync · Uploading 2 files" row with "Beta · app unknown · …", no globe and no gap where it was, and "Wait before closing the lid · 2 files still on the way up". The images stay outside the repository.
- **Queue note:** the coordinator's wait loop never starts a job, because its `pgrep -f "python -m pytest|rebuild.sh"` matches its own command line (and another waiting shell's). These jobs, and two of A6's ahead of them, were run with the queue's own `runner.sh`, one at a time, in queue order.

### Not checked, for P2's and P3's testers (per client)

No generic client is installed on this Mac, so everything below is unverified for Dropbox, Box, Proton Drive, Nextcloud, Synology Drive, pCloud and the rest. For each client, with `Velum --dump` (the cross-check needs a deep adapter to compare against, so it doesn't apply):
- **Folder naming:** does the folder follow "<App>-<account>"? Does the row name the app (the dump's "beta: app …" line), or say "app unknown"? Does the extension's bundle ID start with the app's?
- **Flags (live checklist steps 1–2):** does a new file read waiting → uploading → uploaded, and when? Any error macOS shows during a normal upload (like iCloud's 4355), which would read as "can't upload"? Files left "waiting" forever (scratch or excluded files the client never uploads) would raise stuck alerts.
- **Downloads:** does transfer progress say upload or download?
- **Leftovers:** after signing out or uninstalling, does the folder stop reading as live and drop out?
- **Several accounts** of one client: two folders, two rows, names told apart.
- **Paused, signed out, app quit:** the tier can't see any of these (by design); note what the row shows meanwhile.
- **Dropbox's older `~/Dropbox`** folder (outside CloudStorage) isn't covered.

Once a client's flags are confirmed, the way out of beta is a deep adapter that claims its folders (P2 for Dropbox), or, if wanted, a list of confirmed extension IDs that the lid trusts; neither is built.

### For the owner

- **Decide or keep:** the tier shown by default (decided overnight by the supervisor, the owner's to reverse), and the beta lid rule (while a beta folder is shown the lid never says "Safe"; ••• → Show Other Cloud Folders gives it back).
- **The probe-file cross-check** the card asks for, with your yes: run `build/Velum.app/Contents/MacOS/Velum --cross-check 120` in Terminal, write `velum-test-<time>.txt` at the top of one OneDrive folder while it runs, and watch both columns go waiting → uploading → 0 together; delete the file after about 75 s of quiet. Only the idle cross-check ran tonight.
- **Nothing to see on this Mac** once installed (not installed tonight): there is no generic client here. `--render-panel … --sample beta` shows the tier with made-up rows.
- **Known small edge:** switching the tier off while one of its files is still waiting raises the existing "… was disconnected" alert once.
- **Testers for P2 and P3:** the per-client list above is what they check.

### What changed since this card was written (November 12)

- **This Mac now has three live services:** OneDrive, iCloud Drive and Google Drive. The generic tier must skip folders an adapter claims (`OneDrive-*`, `GoogleDrive-*`).
- **Leftover folders are solved.** `isLiveCloudFolder` (in `SyncProvider.swift`) counts a folder only when macOS answers a clear yes. Leftover folders, and any plain folder, answer "no value", not "no", and the two dated OneDrive leftovers here are correctly ignored. Reuse it.
- **Still untested here** against Dropbox, Box and the rest. Labelling the tier beta still applies.
