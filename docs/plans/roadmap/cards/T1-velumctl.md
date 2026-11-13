# T1 · `velumctl`

**Bucket** T Tools and system surfaces · **Part two** · **Status: done** November 13, 2026 (branch `worktree-agent-a5a6c57c7463dd327`) · **Waits for** C2 · **Runs alongside** P1, C3, A5, A6, S2 · **Feeds** T2, T3, R3

## Brief

Scripts, Raycast and backup jobs want to ask "is everything synced?" without opening a panel. The consultant ranked a `velumctl status --json` fifth among the feature ideas ([memo](../strategy-memo.md) §3, idea 5; §2, "Next", "Also"). Two models exist:
- `Velum --dump` already prints what the panel would show;
- Crisp ships `crispctl` inside its app bundle [V].

Crisp's `RELEASING.md` records a lesson for Homebrew. A cask's `binary` line can only be added after a release that contains the tool; added earlier, it breaks every `brew install`.

The running app holds the live state: its FSEvents streams, its pending list, its transfers. A separate tool can't rebuild that state by itself. Suggested route: on every refresh, the app writes a small snapshot file, and `velumctl` reads it and reports its age. The same snapshot later feeds T2's Shortcuts and T3's widget.

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's](C2-sync-provider-protocol.md#hand-off) and [A1's](A1-safe-to-close-the-lid.md#hand-off) hand-offs, and `DebugDump` in `Entry.swift`.

**The idea:** a departures board. The station (Velum) updates it; anyone walking past (a script) can read it, and the board shows when it was last updated.

## Work

- **The snapshot.**
  - After each refresh, the app writes `~/Library/Application Support/Velum/status.json`, with an atomic write and permissions 0600.
  - Contents: a schema version, when it was written, the lid verdict, and each account's provider, name, state, headline, source, age and counts, with the pending files (names included, since the file stays on this Mac).
- **`Sources/velumctl/`,** a second executable product, copied to `Velum.app/Contents/MacOS/velumctl` by `build.sh`. Its commands:
  - `velumctl status [--json]`
  - `velumctl lid [--json]`. Its exit code is the answer: 0 safe, 1 pending, 2 failing, 3 unknown or not running.
  - `velumctl pending [--json]`
  - `velumctl --version`
- **Missing or old means unknown.** If Velum isn't running, or the snapshot is older than two refresh intervals, the answer is "unknown", never the last good answer.
- **Install:** the README gives the one-line link into a folder on your PATH. R3 adds the cask's `binary` line after a release that ships the tool.

## Done when

- Tests use made-up snapshots and cover:
  - every exit code;
  - the JSON schema (its keys don't change silently);
  - a stale snapshot giving unknown;
  - a missing file;
  - a snapshot with a newer schema.
- Live, on this Mac: `velumctl lid` agrees with the panel. With the user's yes, a probe file flips it to pending and back; the probe is deleted afterwards.

## Ownership and limits

You own:
- `Sources/velumctl/`;
- its product in `Package.swift`;
- its copy step in `build.sh`;
- the snapshot writer, a new file plus one line in the `Store`'s refresh.

The tool only reads. No commands that change anything (pause, restart) for now.

## Hand-off

Built overnight November 13, 2026, in a worktree off `main` at `f07c78d` (A3, A4 and A7 merged). [docs/velumctl.md](../../../velumctl.md) is the user's page: commands, exit codes, and every field of the schema.

### What's built

- **`Sources/VelumStatus/`, a small library** shared by the app (which writes the file) and `velumctl` (which reads it), so the schema is defined once:
  - `StatusDocument.swift`: schema 1 as `Codable` types, the encoder and decoder (ISO 8601 dates with milliseconds, sorted keys), and the atomic 0600 write. The write opens a temporary file with mode 0600 (`O_NOFOLLOW`), writes, closes, then `rename`s it over `status.json`, so the file is never readable by others, even for a moment, and a reader never sees half of it.
  - `VelumCtl.swift`: `StatusReading` (missing, unreadable, newer schema, Velum quit, stale, dated in the future, or self-contradicting all mean unknown), the exit codes, the text output and the argument handling. All of it is reachable from tests.
- **`Sources/velumctl/main.swift`:** a few lines. It finds the app's version through any symlink on the PATH ("dev build" outside an app).
- **`Sources/Velum/StatusFile.swift`:** builds the document from the panel's own `Snapshot` and the Store's summary, then writes it on a utility queue. A write error goes to the debug log once, not every 2.5 s. `StorageFigures` lives here too: an account's storage as numbers with their source, beside the notes line's words.
- **What the file carries:**
  - per service: whether its app runs, its trouble, Google Drive's pause, and A7's compatibility headline with the version, "tested" and how many checks aren't passing;
  - per account: status, headline, detail, source, age, old, A4's reason, notes, upload counts, coverage, the service's own queue, and storage with its source (`googleDriveCache`, `googleSignIn`, `iCloudQuota`);
  - the lid verdict with the panel's words;
  - every file not in the cloud yet (at most 50, failing first), each marked `stuck` by A3's rule, plus A3's stuck count.

### Decisions, with the consultants' views

Codex (`codex exec -s read-only`) and a Fable senior consultant (an advisory-only agent on the Fable model) each read the code and a brief with the exact outputs. Fable's memo caught two real bugs before the first test run: `velumctl lid` printed a footer after its one line, and the "missing" reason ended "running?.". Codex caught the second one too.

| Question | Decision | Codex | Fable |
|---|---|---|---|
| Exit codes | Every command exits with the lid's code. 0 safe; 1 pending or a service's queue still busy; 2 failing or a sync app not running; 3 can't tell; 64 usage | Same | Same |
| A sync app not running | 2, as the panel groups it with failing; 3 stays "Velum can't tell" | 2 | 2 |
| `velumctl` with no command | Runs `status` | `status` | Usage, exit 64. **Split; I took Codex's**: it's read-only and the obvious meaning, and a typo still gets 64 |
| The lid line | "Title. Detail." on one line. The file's detail drops the panel's "See the account below."; no "run velumctl pending" pointer either | No pointer | Add a pointer in the text only. **Took Codex's**: the line stays the panel's own words, and `--help` names `pending` |
| Footer ("From Velum just now") | Dropped: anything old enough for its age to matter is already "unknown" | Drop | Drop |
| `pending` | Every file not in the cloud (threshold 0), with `stuck` marked; text says "· stuck". A3's own hand-off suggested this. The brief said "A3's stuck list feeds pending": its count is `pending.stuck`, and its rule marks each file | All | All |
| Empty `pending` | "No files Velum tracks are waiting to upload." | "No tracked files are pending upload" | This wording |
| Unknown reasons | "There's no status from Velum yet. It isn't running, or has only just started." · "Velum's last status is 4 minutes old. Things may have changed since." · "This velumctl is older than the running Velum. Use the one inside Velum.app." · "Velum isn't running." · "Velum's status file can't be read." · "…dated later than this Mac's clock." | Similar; keep schema numbers | These words |
| JSON names | camelCase, keys with no value left out, sorted. `appsOwnWords` → `headlineFromApp`, `notAsTested` → `checksNotPassing`, velumctl's `age` → `ageSeconds` (it clashed with the account's word-age) | `headlineFromClient`, `unexpectedCheckCount` | These |
| `status --json` | The whole file plus `fresh` and `ageSeconds` (Codex noticed `refreshEvery` was missing) | | |
| Missing vs unreadable | Told apart: a file that exists but can't be read says so | Bug found | |
| Exit code from the file | Always redone from the verdict, so a file whose fields disagree can't exit 0 | | Bug found |
| Clock set back | A status dated more than 1 s ahead is unknown (was 30 s, longer than the 5 s budget) | Flagged | Flagged |
| `refreshEvery` from the file | Capped at 30 s; not a positive number counts as 2.5 s | Validate | Cap at 60 s |
| "Safe" that contradicts itself | Unknown: a file saying safe while a service is stopped, an account has files waiting or failing, isn't fully watched, or its service is still busy. The app can't write that; velumctl checks anyway, against exactly the lid's own conditions | Asked for it | Asked for it |
| Staleness | 2 × `refreshEvery`, at least 5 s, as the card says. Measured live: across 240 samples over two minutes with the panel closed, the status was never older than 2.5 s and always fresh | Keep 5 s, measure first | 4×, at least 10 s |
| Install line | `sudo mkdir -p /usr/local/bin && sudo ln -sf ~/Applications/Velum.app/Contents/MacOS/velumctl /usr/local/bin/velumctl`: `/usr/local/bin` is on macOS's own PATH. The doc mentions `~/.local/bin` and full paths for `launchd` jobs | `~/.local/bin` | `/usr/local/bin` |
| Apostrophes | Curly, as in the panel, in the usage text too | Curly | Curly, consistently |

Not taken:
- **Codex: stamp the file with the refresh's start, not its end**, since the upload evidence is read at the start. Kept the end. The evidence is at most one collection older than the stamp, the panel shows the same snapshot for the same 2.5 s, and stamping the start would make a slow refresh look stale.
- **Codex: the tracker ends a coverage gap after 15 minutes without re-checking.** That's real, but it's A4's and the tracker's: `Reasons.coverageGap` already notes it as a follow-up. velumctl reports what the panel reports.

### Tests

`Tests/VelumTests/VelumctlTests.swift`, all with made-up snapshots under `/Users/test` and example.com accounts, writing only to temporary folders. Run through the shared queue: 189 tests, 25 of them new. All pass except the four known failures on this branch's base, stale "No status yet" and "Status unknown" wording from the wave 2 merge, which `main` fixed at `3c3e311`. The first run crashed on one of my own tests (JSON can't encode infinity); fixed and rerun. It covers:
- every exit code (each verdict, every command, usage errors, help, version, no command);
- the schema: the full key list pinned (a renamed or dropped key fails the test), lid keys across every verdict, each command's JSON keys, and a round trip to the millisecond;
- stale (at the edge and past it), missing, unreadable, Velum quit, newer schema (with unknown keys and with nothing but `schema`), dated in the future, a bad `refreshEvery`, and a "safe" that contradicts itself or carries a forged exit code;
- the 0600 atomic write, which also resets a file someone made world-readable and leaves no temporary file;
- the app side: three services and five accounts, two of them Google accounts (`googledrive:<email>`), storage and its source, Google's pause, A7's headline, the stuck marking, every lid verdict and state, and a real `Store` written and read back;
- the text of `lid`, `status` and `pending`.

### Live check

November 13, 2:45–3:00 AM, with probe files pre-approved for the night. No screenshots or real names here; renders stayed in the session's scratchpad.

1. **The bundle.** `./build.sh` through the queue, no install. `Contents/MacOS/velumctl` is signed with the local identity, `codesign --verify --strict` passes, and `--version` reads "velumctl 1.0 (1) · status schema 1", directly and through a symlink.
2. **A first attempt that went wrong.** To leave the installed Velum alone, I first ran a renamed copy with its own bundle id. Its new identity made macOS ask for access to a watched folder: its main thread sat in `open()` inside `FSEventStreamCreate`, so it wrote one status and stopped. It also turned on Open at Login for itself (`LoginItem.enableOnFirstLaunch`). I stopped it within a minute and deleted the copy. `velumctl` then said "Velum isn't running.", exit 3. Two leftovers wait for you (below).
3. **The check itself,** done as A3's was. I quit the installed Velum and opened this branch's build in its place for about ten minutes. Same bundle id and signing identity, so nothing asked anything. Then I reopened the installed app.
   - **Agreement:** `velumctl lid` said "Safe to close the lid…", exit 0, and `velumctl status` gave the build's own summary and rows. Both come from the panel's `Snapshot` and the Store's summary string, so they agree by construction (and by test).
   - **Cadence:** across 240 samples over two minutes, the status was never older than 2.5 s and never stale.
   - **The panel:** a live `--render-panel` from the same build showed "Wait before closing the lid": the second OneDrive account "still syncing". Every fresh `--dump` agreed, with `other 1` in that account's transfers, while the running build and `velumctl` said "Safe". The cause is `TransferMonitor`, not T1. A direction-less transfer that hasn't moved for 120 s counts as stalled, and that clock starts when a monitor first sees it. The running build had watched long enough to drop it; a seconds-old `--dump` or `--render-panel` process counts it as syncing. See "For later cards".
   - **Probe 1,** `velum-test-<time>.txt`, written at the top of the Personal OneDrive in one go. It uploaded between two refreshes, so the lid never left "safe" (sampled every 0.25 s). OneDrive's own history recorded it.
   - **Probe 2,** grown a line every half second for 15 s, like a file saved in pieces. The lid went "busy", then "pending 1", back to "safe" between bursts, and settled on "safe".
     - While the lid said "1 file still on the way up", `velumctl pending` said "No files Velum tracks are waiting to upload". The lid also counts uploads that macOS reports in progress before the tracker has checked the file.
     - Fixed: the line now reads "Velum can't name it yet: macOS reported the upload before Velum checked the file", with a test. This fix came after the build, so the build used live doesn't have it; the test run does.
   - **Clean-up:** each probe was deleted 80–90 s after its last edit and was still gone 40 s later.
   - **The file:** 4.5 KB, mode 0600. It carried Google Drive's pause (false), storage from Drive's cache and from `brctl quota`, A7's headlines for all three services, and A4's reason on the account that can't tell.
   - **After quitting the build:** "Velum isn't running.", exit 3. The installed Velum reopened. It is `main`'s build and doesn't write the file yet, so `velumctl` says so, never the last answer. I removed the leftover file.

Not checked live, covered by tests: exit 2 (a failing upload, or a stopped OneDrive or Google Drive; quitting them was off limits tonight), a newer schema, an unreadable file, and the "Velum can't name it yet" line. Nobody looked at the real panel with their own eyes: there was no screen access overnight.

### For the morning

- **A macOS privacy prompt** is probably on screen behind the lock screen. It is from "Velum T1 test", my throwaway copy, asking for access to a folder. The copy is deleted; click **Don't Allow**.
- **System Settings → General → Login Items:** if "Velum T1 test" is listed, remove it. I left it for you because Login Items are yours to change.
- **Two splits between the consultants,** settled as Codex suggested: a bare `velumctl` runs `status`, and the lid line has no "run velumctl pending" pointer. Say if you'd rather have Fable's.
- **After the merge:** `./build.sh --install`, then link the tool with the README's `sudo` line if you want it on your PATH.

### For later cards

- **`--dump` and `--render-panel` overstate a stalled transfer** for their first 120 s of life, as the live check found. Anyone comparing a dump with the running panel (S2's diagnostics, a future live check) should know. `Progress` doesn't say when a transfer last moved, so a seconds-old monitor can't tell stalled from active; the fix, if any, belongs to whoever next owns `TransferMonitor`.
- **T2 and T3:** read the file with `StatusReading.read()` from `VelumStatus` and take `lid` from the reading, never from the file directly, so the stale and missing rules come with it. T3's app-group copy can be one more `write(to:)` in `StatusFile.write`.
- **R3:** the cask's `binary` line goes in only after a release that ships `velumctl` (Crisp's lesson).
- **S2:** `status.json` names files. If the diagnostics export includes it, redact `pending.files`, `accounts[].uploads.firstFailure`, account names and keys.
- **R1:** `Scripts/sign.sh` now signs `Contents/MacOS/velumctl` before the app, with the same identity. Developer ID signing and notarization must do the same, with the hardened runtime.
- **Disk:** the file is about 4.5 KB here (more with many files pending), rewritten every 2.5 s while Velum runs: roughly 150 MB of writes a day. Fine for an SSD; if that ever matters, write only when the content changes plus a heartbeat every few seconds, and keep `refreshEvery` honest about the heartbeat.

### For merging

Edits to shared files are on their own lines, each marked `T1`:
- `Model.swift`: `AccountStatus.storage`, `ProviderStatus.paused`, one line in `Collector.collect`, one in `Collector.status`, `Store.refreshEvery` (the timer now uses it), and two lines in `Store.refresh` (the full pending list, and the write after `onRefresh`). A6's hook in `Store.refresh` should sit on its own line beside them.
- `SyncProvider.swift`: `ProviderEvidence.paused`, `AccountEvidence.storage`.
- `GoogleDriveProvider.swift` and `ICloudProvider.swift`: one line each setting `storage`, and Google's `evidence.paused`.
- `Package.swift`: the `VelumStatus` library, the `velumctl` executable, `VelumStatus` added to the app's and the tests' dependencies.
- `build.sh`: the copy line. `Scripts/sign.sh`: the nested signing (R1's file, three lines).
- `README.md`: one "What you get" bullet, the install line under Install, and the Uninstall step.
- `PanelView.swift` is untouched: the lid's words live in both `LidRow` and `VelumStatus.Lid`, pinned by tests on the velumctl side. Change them together.

### What changed since this card was written (November 12)

- **The snapshot should carry, per service:**
  - whether its app runs;
  - its trouble ("Storage full");
  - Google Drive's pause.
- **Per account:**
  - storage figures and their source (Drive's cache or the optional sign-in);
  - the notes line.
- **Accounts come and go at run time.** Consumers must treat the list as dynamic: keys like `googledrive:<email>`, any number per service.
