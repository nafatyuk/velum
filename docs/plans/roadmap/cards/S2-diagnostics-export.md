# S2 · Diagnostics export, redacted

**Bucket** S Support · **Part two** · **Status: done** November 13 · **Waits for** C2 · **Runs alongside** P1, C3, T1, A5, A6 · **Feeds** G1

## Brief

When Velum shows the wrong thing on someone else's Mac, the only way to fix it is to see what Velum saw. The obvious report is `Velum --dump`, but it is full of personal detail:
- account names and email addresses;
- organization names;
- folder paths with the user's name in them;
- file names.

The consultant's ninth idea is a diagnostics export with automatic redaction ([memo](../strategy-memo.md) §3, idea 9). G1's issue templates will ask for exactly this report (§5, item 6).

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off), `DebugDump` in `Entry.swift`, and A7's compatibility check, if it has landed.

**The idea:** a medical chart with the patient's name blacked out. The doctor still sees every reading.

## Work

- **`Diagnostics.swift` builds the report.** It holds:
  - Velum's version, macOS's version, and each client's version;
  - A7's checks;
  - for each account: provider, kind, state, source, age, counts and coverage gaps;
  - transfers;
  - the tracker's numbers;
  - recent failure reasons;
  - settings toggles.
- **Redaction:**

  | Replaced | With |
  |---|---|
  | Account names and emails | "Account 1", "Account 2" |
  | Organization names | `<org>` |
  | The home folder | `~` |
  | Folder paths under a root | `<root>/…` |
  | File names | `file-1.docx` (the extension is kept, because it often matters) |
  | Text inside failure reasons | The same replacements |

  Replacements stay consistent within one report.
- **Two ways in:**
  - `Velum --dump --redact`;
  - the ••• menu's "Export Diagnostics…", which writes a `.txt` file and shows it in Finder so the user can read it before attaching it anywhere.

  Velum never sends it anywhere.

## Done when

- **A redaction test corpus:** made-up accounts, emails, organizations, paths and file names (including Unicode, spaces, and names that are also ordinary words) go in, and none survives.
- **Live on this Mac:** an exported report, checked by a script that takes the strings to look for from the live configuration at run time, shows none of the user's account names, emails, organization names or file names. The script never writes those strings to the repo or a log.

## Ownership and limits

You own:
- `Diagnostics.swift`;
- the `--redact` flag in `Entry.swift`;
- one ••• menu line in `PanelView.swift`.

No uploads, and no "send to developer" button.

## Hand-off

Built overnight on November 13, 2026, on `main` at `f07c78d` (after A3, A4 and A7), with this card's "What changed" notes: Google addresses and `GoogleDrive-<email>` folders, DriveFS's numeric IDs, storage figures, each service's evidence, where storage came from, and the debug log.

### What it does

- **One report, two ways in:**
  - `Velum --dump --redact` prints it in Terminal, from a fresh look like `--dump`;
  - ••• → **Export Diagnostics…** (always shown, right under Open Debug Log) writes `Velum Diagnostics 2026-11-13 at 02.14.05.txt` to `~/Library/Logs/Velum` and shows it, selected, in Finder. If the write fails, an alert says "Velum couldn’t save the diagnostics report", then the system's reason and "Nothing was saved."
  - Plain `--dump` is unchanged. Nothing is ever uploaded. There's no "send" button.
- **What's in it:**
  - a header saying what was replaced, that Velum can't recognize everything, and where the report was read from (the running app, or Terminal);
  - Velum's version, its build time and how long it has run; macOS, the Mac model, chip and language; each client's version;
  - settings: alerts, Open at Login, Debug Logging, OneDrive's Accessibility, the stuck threshold, each Google account's sign-in switch;
  - the lid line, as the panel words it plus the raw verdict;
  - each service: app running, icon text readable, Desktop & Documents in iCloud, Google Drive paused;
  - A7's compatibility checks;
  - per account:
    - status, headline, source and age, the reason, notes, and the row's detail line;
    - **evidence**: OneDrive's hourly report (code, files to upload and download, files, folders, pid, when written), iCloud's `brctl status` essence, Google Drive's queue count and pause;
    - **storage**: where the figure came from (Google Drive's cache, the optional Google sign-in, `brctl quota`, or none);
    - the tracker's counts and coverage, the service's own queue, transfers (as a percentage, never bytes), OneDrive's process and icon text, and the watched folders;
  - "Not in the cloud yet" (A3) with paths and failure reasons;
  - the newest 10 activity items;
  - the debug log's last 24 hours, at most 500 lines, from `Velum.1.log` and `Velum.log` in order, with its time span and whether it was capped.
- **Sign-in tokens never get in.** The report never reads the Keychain, and a token shape (`ya29.`, `1//…`, a JWT) in a log line becomes `<token>`.

### How redaction works (`Redactor` in `Diagnostics.swift`)

- **Fields are redacted as the report is built**, so Velum's own labels never go through the matcher. Only text Velum doesn't word word for word is swept: reasons, notes, check details, failure reasons and log lines.
- **What it knows, from the live configuration:**
  - every account's name, fallback name and address;
  - the organization as its `OneDrive-<Org>` folder spells it, with and without spaces;
  - the user's short and full names, the Mac's name;
  - DriveFS's numeric folders;
  - the synced folders, and the file names in the stuck list, Recent and failures.
- **What it learns from the debug log's own shapes**, so accounts since removed and files no longer pending go too:
  - `X [OneDrive]: appeared|gone`, `X: ok → syncing`;
  - `first: <file>: `, `can’t upload · <file>: `;
  - quoted names with an extension.
- **The order of the sweep:** tokens, web addresses, synced-folder paths, the home folder, other homes and volumes, the known names (longest first, whole words, any case, Unicode-normalized), then stray addresses, `OneDrive-`/`GoogleDrive-` folder names, long numbers, byte figures and storage percentages. Text from macOS and the log also loses anything in curly quotes and any word with a file extension, except Velum's own files (`Velum.log`, `SyncDiagnostics.log`…).
- **The labels**, consistent within one report:
  - "Account 1"… for the panel's accounts in order, then accounts only the log knows;
  - `<email 1>` for addresses tied to no account, `<org 1>` for organizations tied to no account;
  - `~`, `/Users/<user>`, `/Volumes/<volume>`;
  - `<root>/…/file-1.docx` (the synced folder is shown redacted, with its inside folders always "…", whatever their depth);
  - `<size>`, `<percent>`, `<id 1>`, `<url>` (`<url at sharepoint.com>` for a well-known service), `<user>`, `<computer>`, `<token>`.
- **Limits, on purpose:**
  - names under 3 characters aren't swept from free text (a file called "a" would take every "a"), though fields still are;
  - Velum's own words ("Personal", "iCloud Drive", "My Drive"…) are never treated as names;
  - an organization called "Drive" takes "Drive" out of "Google Drive": over-redaction is accepted.

### New files

- `Sources/Velum/Diagnostics.swift`:
  - `Redactor`;
  - `DiagnosticsInput`, everything one report shows, gathered once so tests can feed made-up input;
  - `DiagnosticsReport`: gathering, rendering, the menu export and the Terminal print.
- `Tests/VelumTests/DiagnosticsTests.swift`: the redaction corpus.
- `Scripts/check-redaction.py`: the live check. `Scripts/` is R1's folder; this adds a file and touches nothing else there.

### Shared-file edits (each on its own line)

- `Entry.swift`: the `--dump --redact` line; `collectOnce` is no longer `private`.
- `PanelView.swift`:
  - `PanelActions.exportDiagnostics`, with a default, so `AppDelegate.swift` is untouched;
  - the menu line;
  - `LidRow.title` and `.subtitle` are no longer `private`, so the report words the lid as the panel does.
- `Model.swift`: `AccountStatus.storageSource` and its copy in `Collector.status`; `Store.transferSnapshot`.
- `SyncProvider.swift`, `GoogleDriveProvider.swift`, `ICloudProvider.swift`: `AccountEvidence.storageSource`, one line each where storage is read.
- `README.md`: a paragraph under "Troubleshooting: the debug log", the Limits line now points to the export, and `--dump --redact` in the `--dump` block.

### Decisions (Codex CLI and the Fable consultant, November 13)

| Question | Codex | Fable | Decided |
|---|---|---|---|
| Menu label and place | "Export Diagnostics…", above Debug Logging, always shown | "Export Diagnostics" (no ellipsis, nothing more is asked), under Open Debug Log, always shown | **"Export Diagnostics…" under Open Debug Log.** The ellipsis is your card's own wording and Codex's pick; the place is Fable's, which keeps the log's two items together |
| Where the file goes | Always `~/Library/Logs/Velum` | The same | **`~/Library/Logs/Velum`**: never a synced folder (Desktop and Documents are in iCloud here) |
| File name | With seconds, a suffix on collision | Minutes; replacing is fine | **Seconds plus " 2" on collision**: nothing is ever overwritten |
| A failed write | A native alert | A native alert, "Velum couldn’t save the diagnostics report." + the reason + "Nothing was saved." | **Fable's words** |
| Org names, stray addresses | Known → "Account N"; unknown `<org N>`, `<email N>` | Known → the account's label; stray address `<email 1>` | **Both agree**: "Account N" only ever means a row |
| Storage | Every byte figure `<size>`; storage percentages `<percent>`; keep transfer progress | Every byte figure `<size>`; keep percentages; transfers as a percentage | **Codex on percentages** (they still disclose usage; the state survives), **both on transfers** |
| Debug log | Last 24 h, capped at 500, both files | Last 200 lines, both files | **24 h, at most 500 lines, both files**, saying the span and the cap |
| Over-redaction | Accept in free text | Redact fields as built; sweep only free text | **Both** |
| Header | "…hasn’t uploaded this report… read it before you share it" | Admit the limit: "It can’t recognize everything, so read it before you share it." | **"Velum doesn’t send it anywhere" plus Fable's admission** |
| `--dump --redact` | The same report | The same report | **The same report** |
| Gaps they found | Removed accounts and old file names in the log; collection mode; coverage; every watched root; truncation; the lid in words | The same log point; the user's and Mac's names; `/Volumes`; SharePoint names; URLs; build, chip, language, uptime, Desktop & Documents | **All taken**, except: Velum has no commit stamp to show, so the report gives the executable's build time |

### Velum's own defaults (A5's `sleepGuardWatch` and later keys)

- **The report never dumps Velum's defaults.** It reads named settings only:
  - `notificationsEnabled`;
  - `stuckAfterSeconds`;
  - `debugLogging`;
  - `googleSignInAccounts`, shown only as on or off per account label.

  So `pendingUploads`, `recentUploads` and A5's `sleepGuardWatch`, which all hold file paths, can't get in, nor can any key added later. That is deny-by-default by construction.
- **The live check walks every key.** It decodes every value under every key (JSON or plist inside data), whatever the key. Anything shaped like a path in the home folder or on a volume counts as personal, and so does a `name` beside a `path`. A5's key is covered without A5's code.

### Checks

- **Tests:** one queued run, `Scripts/test.sh` then `./build.sh` (no install).
  - 174 tests; all 10 in `DiagnosticsRedaction` pass.
  - The 4 failures are the ones known on this base from the wave 2 merge, and nothing else: `anUnknownCodeIsUnknownNeverHealthy`, `aReportWithoutItsCodeLineIsDropped`, `anUnreadableQueueMeansNoStatusAndNoSafeLid` and `unreadableQueueIsNoStatusButCountsFlags`. They expect A4's old wording ("No status yet", "Status unknown") and are fixed on `main` at `3c3e311`.
  - `./build.sh` built `build/Velum.app`.
  - Before queueing, one niced `swiftc -typecheck` of the module plus the new tests (9 s, no build) ran outside the queue, so a compile slip wouldn't waste a slot.
- **The corpus** (`Tests/VelumTests/DiagnosticsTests.swift`) builds a whole report from made-up input:
  - 6 accounts, with organizations "Zürich Café & Co" and "Delta" (an ordinary word), Google addresses with Unicode (one decomposed in the log), and DriveFS IDs;
  - a home folder, the user's and the Mac's names, a volume, storage figures and a percentage;
  - stuck files with Unicode, spaces and brackets in their names;
  - log lines naming an account since removed, failed files, a SharePoint URL, sign-in tokens and a stray address.

  None of its 41 personal strings survives, in any case. Other tests check consistency, paths, whole words, Unicode, quotes, the 24-hour window and cap, and the export writer.
- **Live on this Mac:** `Scripts/check-redaction.py` read 150 strings from the live configuration at run time, in 10 kinds:
  - account names, the email, organizations (including SharePoint site and library titles and the tenant);
  - the user's names, the computer name, the home folder;
  - the DriveFS ID;
  - 75 file names and 51 folder names (OneDrive's activity, Velum's saved state, the debug log);
  - iCloud's quota figure.

  It then ran `build/Velum.app`'s `Velum --dump --redact` and found **nothing** in the 608-line report, which included the debug log's newest 500 lines. It prints no strings and writes nothing.
- **The checker itself:** the same checker on plain `--dump`, piped in and never written to disk, flagged 62 lines across 11 kinds (names, emails, organizations, file names, the home folder, byte figures, web addresses). So a clean result means something.
- **Reading the report:** every section was there with consistent labels. One live log line held a real failing upload's name, and it came out as `file-N.txt`.
- **Not checked:**
  - clicking ••• → Export Diagnostics… in the running app;
  - the Finder reveal;
  - the alert on a failed write.

  These need the app installed (see below). The writer and the report it writes are tested.

### For the morning

1. **Try the menu after install (at your word).** Once this is merged and installed, click ••• → **Export Diagnostics…** once. The file should appear, selected, in Finder under `~/Library/Logs/Velum`. Read it, then run `Scripts/check-redaction.py --file "<that file>"`; it should say "nothing personal found".
2. **Look at the label in the real menu.** Export Diagnostics… sits under Open Debug Log. Fable would drop the ellipsis because nothing more is asked. It's kept because your card and Codex use it.
3. **One finding on this Mac (A7, not S2).** Tonight OneDrive's Business2 report has no `SyncProgressState` line, so A7 marks it "changed", and the log shows its alert as Velum's banner. The report shows this clearly; it isn't a redaction issue.

### Left out, or for later cards

- **No commit hash in the report.** Nothing stamps one into the binary yet; R1's release script could, and the report would show it.
- **The menu path isn't exercised end to end by a test.** The writer and the report are, and so is the same report from Terminal; clicking the item is in "For the morning".
- **Counts and times stay.** They are what a maintainer needs, but files-per-account counts and timestamps could still say something about a person. The header says to read it first.
- **G1's issue template** should ask for this report (••• → Export Diagnostics…) and say that it's redacted but worth reading.

### What changed since this card was written (November 12)

- **More to redact:**
  - Google Drive account names are email addresses, and they appear in folder names (`GoogleDrive-<email>`);
  - DriveFS folders are named by a numeric Google account ID;
  - storage figures are personal.

  The redaction corpus needs all three.
- **More to report:** per service, the evidence each row used (OneDrive's report, iCloud's `brctl`, Google Drive's queue and pause), and where storage came from (Drive's cache or the optional sign-in). Never include the sign-in's tokens.
- **A debug log exists now (November 12, the owner's request).** ••• → Debug Logging writes status changes, alerts, gaps and failures to `~/Library/Logs/Velum/Velum.log` (`Sources/Velum/DebugLog.swift`, 2 MB rotation). S2's export should include its recent lines, redacted like the rest, since that's where "what happened an hour ago" lives.
