# A6 · Sync history per account

**Bucket** A Assurance · **Part two** · **Status: done** (November 13, 2026) · **Waits for** C2 · **Runs alongside** P1, C3, T1, A5, S2 · **Feeds** S2

## Brief

The worst sync failure is the silent one: an account that stopped syncing days ago while every glance at the icon looked calm. Velum shows the present and a list of recent activity, but no shape over time. The consultant's seventh idea is a sync history sparkline per account, which "makes silent multi-day stalls visible" ([memo](../strategy-memo.md) §3, idea 7). The memo groups it with ideas 1, 2, 6 and 9 as the ones that move Velum "from icon tidier to sync assurance".

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off) and `AccountRow` in `PanelView.swift`.

**The idea:** a heart-rate trace instead of a single pulse check. A flat line with work waiting is the thing to notice.

## Work

- **`History.swift`:** one record per account per hour, holding:
  - uploads completed;
  - downloads;
  - the most files waiting;
  - failures;
  - whether coverage had a gap;
  - whether the status was unknown.

  Counts only, never file names. It is stored in `~/Library/Application Support/Velum/` and kept for 30 days (your decision).
- **Quiet and stalled are different.**
  - *Quiet:* nothing changed, nothing waiting. A quiet line is fine.
  - *Stalled:* files waiting and none uploaded. A stalled stretch stands out in the line and in the account's detail ("stalled for 2 days").
- **`SparklineView.swift`:** a small, plain sparkline in each account's row, or its detail line, covering the last 7 days. It has an accessible summary ("Uploads on 6 of the last 7 days; stalled since Tuesday").
- **No gaps invented.** Hours when Velum wasn't running show as unknown, not as quiet.

## Done when

- Tests cover:
  - bucketing by hour;
  - keeping 30 days;
  - quiet versus stalled;
  - hours when Velum wasn't running;
  - no file names stored (checked on the written file).
- History survives a restart.
- Screenshots of the row, light and dark, and with VoiceOver's summary.

## Ownership and limits

You own `History.swift`, `SparklineView.swift`, and one line in `AccountRow`. Draw with SwiftUI only. Keep the row's height.

## Decisions for the user

| Decision | Suggested |
|---|---|
| How much history to keep | 30 days, on this Mac only |

## Hand-off

_Built November 13, 2026, overnight, in its own worktree (branch `worktree-agent-a07f29520d61ef2e2`, from `f07c78d`), alongside T1, A5, S2 and G2. Codex and the Fable consultant were asked in two rounds; Fable ruled every conflict. Their memos are summarized here, not committed._

**What the owner sees**
- **A 3 pt strip under each account**, in the row's existing bottom padding (x 52–324 of the 340 pt panel), so no row gets taller. It shows the last 7 local calendar days, hour by hour, with a 1 pt break at each midnight; today ends at the current hour.
  - **Uploads:** a full-height mark, `primary` at 60%. No heights by count: 3 pt can't carry them honestly.
  - **Quiet** (watched, no uploads, nothing waiting 10 minutes or more): a 1 pt baseline, `primary` at 22%.
  - **Stalled** (work waited past 10 minutes for at least 5 minutes of the hour, and nothing uploaded): orange, 3 pt on and 1 pt off, so it differs from failing by shape and not only by hue.
  - **Failing:** solid red.
  - **Blank:** hours Velum wasn't running or the Mac slept, hours it may have missed changes, before history began, and the rest of today.
  - Never green, and never blue (blue means "syncing now" on the row).
- **Compact rows** (healthy rows when there are more than 6 accounts) have no strip; VoiceOver still reads their history.
- **A stall of a day or more leads the source line**, in the same tertiary caption, with no new line: "Stalled for 2 days, since Tuesday · waiting since 2:15 PM · Live from macOS". When Velum didn't watch the whole stall (the Mac slept, for example), it says only "Stalls seen since Tuesday": counts can't prove the same files waited throughout. On a short source line this can wrap it from one line to two (Fable's flag).
- **VoiceOver** reads the history after the reason, notes and source line, in the row's value. The strip itself is hidden from VoiceOver.
- **Hovering the strip** shows: "Last 7 days, oldest on the left; today is partial. {summary} A flat line means no uploads and nothing waiting 10 minutes or more. It doesn't mean up to date."
- **The legend** ("What the Status Means") gains one line under Recent and notes, explaining every mark and ending "It is never green: history can't show an account is up to date."

**The words** (`HistoryLine.make`)

| Case | Summary |
|---|---|
| A full week | "Uploads seen on 6 of the last 7 days." / "No uploads seen in the last 7 days." |
| History began this week | "Uploads seen on 2 of the 3 days since history began." |
| History began today | "Uploads seen today, since history began." / "No uploads seen since history began today." |
| Stalled now (live evidence only) | "…; stalled since Tuesday." / bridged: "…; stalls seen since Tuesday." |
| Failing now (live evidence only) | "…; uploads failing since Tuesday." |
| Time not watched (an hour or more) | "Velum wasn't watching for 31 hours of that." (48 hours or more: "about 3 days") |
| Coverage gaps | "Velum may have missed changes on 2 days." |
| A file stuck while others uploaded | "Files waited past 10 minutes on 2 days." |
| No records | "No sync history yet." |

"Since" reads "2 PM" today, "yesterday", a weekday within the week, then "Oct 28". "Now" clauses need a refresh in the last 5 minutes; the hour records alone never say "now".

**The data** (`History.swift`)
- `HistoryHour`, one per account per UTC hour: seconds watched, uploads Velum saw finish, uploads and downloads in the service's own history (OneDrive only), the most files waiting, the most stuck and the seconds anything was stuck, the most failing, and seconds with a coverage gap or an unknown status. The card's "whether coverage had a gap" and "whether the status was unknown" are `gap > 0` and `unknown > 0`; seconds were kept so that a 3-second "not watching yet" blip at launch doesn't mark a whole hour.
- **Classes, worst first:** failing; stalled; active (uploads); not watched (under half the hour, so far, for the current hour); unsure (a gap of 5 minutes, or half the watched time); quiet. An unknown status doesn't change the class: the tracker's own evidence still stands, as A4's "Nothing is waiting to upload." does (both consultants agreed).
- **Uploads** come from two floors, and the hour uses the larger (`HistoryHour.uploaded`), never the sum:
  - `uploads`: a new per-account counter in `UploadTracker` (`uploadedCounts()`), on the same rule as Recent (a changed file seen waiting or uploading, then in the cloud). It covers every service and account alike.
  - `reported`: uploads in the service's own history, for services that keep one (OneDrive). Found live tonight: OneDrive Personal sent a small test file up in about 2 seconds ("not uploaded" at 0 s, uploading at 1 s, uploaded by 2 s, per `fileproviderctl`), before the tracker's first look, so the tracker alone missed it.
  - Each count only ever misses uploads, so the larger is still never more than happened.
- **Watched time** is credited between refreshes, split at the hour, from whole-second timestamps so 2.5 s steps add up exactly. A step longer than 5 minutes isn't credited, and sleep and wake reset the clock (`NSWorkspace` notifications), so hours asleep or not running stay blank, never quiet.
- **Stored** in `~/Library/Application Support/Velum/history.json` (version 1, account key → hours; zero fields omitted), pruned to 30 days on load and at each new hour, saved every 5 minutes, at each new hour or visible change, before sleep and at quit. An unreadable file starts afresh. Account keys are stored as Velum keys them, so a Google Drive key holds its email address. That is a local file on this Mac; S2's redaction should cover it if the export ever includes it.
- `History.shared.record(...)` is the hook in `Store.refresh` (one line); `AccountRow` observes `History.shared`.

**Shared-file lines**
- `Model.swift`: one line in `Store.refresh`, and the "waiting since" line in `Collector.status`.
- `PanelView.swift` (`AccountRow`): one property, one `.overlay` line, two computed properties, and the two lines that read the source line and the VoiceOver value. More than the card's "one line", because the stall note and VoiceOver live in the row's text.
- `Entry.swift`: three lines (`--history-probe`, the render sample, a `history:` line in `--dump`).
- `UploadTracker.swift`: the counter (three small additions). `LegendView.swift`: one bullet. `README.md`: one "What you get" bullet and a word in Uninstall.

**Tests:** `Tests/VelumTests/HistoryTests.swift`, 35 tests in six suites, all with made-up accounts and a throwaway history file:
- bucketing: UTC hour numbers, steps split at the hour with no rounding drift, each refresh's counts in its own hour, every account of every service recorded, a stuck queue counting as stuck work;
- retention: exactly 720 hours kept, pruning at a new hour and at load, a restart reading back the same hours, an unreadable file starting afresh;
- quiet versus stalled: nothing waiting, a short wait (quiet), stuck with no upload (stalled), stuck with an upload (active), a stall under 5 minutes, failing first, stalled now (continuous and bridged), a short stall spoken but not noted, failing now, a file stuck beside uploads;
- not watched: hours without Velum left blank and counted as "wasn't watching", sleep and long steps not credited, a mostly unwatched hour never quiet, gaps making an hour unsure, coverage and status seconds, a stopped app not counted as a gap;
- the file: no file names, paths, folders, apps or failure text in the written file (checked on the file itself, with only known keys), downloads counted once and only from launch, OneDrive's own upload record catching uploads too fast for the tracker, and the larger count rather than the sum;
- the words and layout: every summary form, "since" forms, "waiting since" with its day, the tooltip, 7 local days with today only so far, and a 25-hour daylight-saving day.

`Scripts/test.sh` through the shared queue (final run, November 13): 199 tests; all six A6 suites pass and the build has no new warnings. The only failures are four in `CompatibilityTests` and `GoogleDriveTests`. They come from the wave 2 merge in the base `f07c78d`, not from A6: stale "No status yet" and "Status unknown" wording, fixed on `main` at `3c3e311`. Earlier runs caught a main-actor default argument, a race in `save(wait:)` (it returned before a queued write landed) and a Sendable warning; all three are fixed.

**Screenshots** (light and dark, made-up data) are in the session's scratchpad, not the repo: `Velum --render-panel out.png --sample healthy|unknown|old [--sample-stall] [--dark] [--legend] [--many]`. `--sample` now also fills made-up history (awake 8 AM to midnight, nights blank); `--sample-stall` turns the second account into one waiting with three files since two days ago. Each render prints every account's spoken summary, which stands in for a VoiceOver screenshot.
- **Heights unchanged:** the healthy sample renders 677 pt and the old sample 759 pt, the same as A4's renders before A6. The stall sample is also 677 pt; there the stall note shares the source line.
- `--many`: compact rows show no strip and keep one line.
- The legend grows from 748 to 852 pt; on short screens it scrolls, as before.
- Spoken, for the stalled sample: "Uploads seen on 4 of the last 7 days; stalls seen since Wednesday. Velum wasn't watching for about 2 days of that." The row's source line read "Stalls seen since Wednesday · waiting since 12:45 AM · Live from macOS" before the fix below; it now ends "waiting since Wed 12:45 AM".
- **Sign-off on the renders (round 3):** Codex and Fable both said "ship", with no blocking problems. Fable's nice-to-haves, done: a stalled run's last dash is never a sliver under 2 pt; the sample keeps its last few hours awake, so a night-time render still shows today; the sample has a red failing stretch on record; and "waiting since" names the day (below). Fable's one check: the stall render ended blank only because it ran at 3 AM, inside the sample's made-up night. Live, the current hour is always recorded; the probe confirmed it.

**Checked live, without replacing the installed app**, with `Velum --history-probe <seconds> <file>` (new, in `History.swift`). It runs the real sources from the debug build and records into a scratch file, never the real one.
- One pre-approved test file (`velum-test-<time>.txt`) each in OneDrive Personal, iCloud Drive and Google Drive's My Drive, during a 200 s probe. Each was deleted after the probe, more than 75 s after its only write.
- iCloud Drive and Google Drive each recorded `uploads 1`, with `waiting 1` while it went up.
- OneDrive Personal recorded nothing, which led to the `reported` count above. The fix has unit tests but no second live run: it needs Recent's OneDrive entries, which the probe reads the same way the app does.
- **Restart:** a second 30 s probe on the same file loaded the first run's hours and added to them (watched 198 s, then 225 s; the uploads kept).
- **No file names:** `grep velum-test` on the probe's file found nothing.
- The probe saw two accounts unknown for part of the run (a OneDrive work account with no report yet; iCloud's first check), and recorded those seconds as `unknown`.
- `Velum --dump` from the debug build prints a `history:` line per account. It reads "No sync history yet." until the installed app has A6, since the probe never writes the real file.

**Decisions, with the consultants' views**
1. **Placement: a strip in the bottom padding (P3).** Codex and Fable both chose it independently over the source line's end (P1: the OneDrive source line already wraps), beside the name (P2: costs name width) and a line of its own (P4: grows every row).
2. **Hourly cells on local days, no counts in the height.** Both. Fable: day breaks make "since Tuesday" findable; 6-hour or daily cells would average a stall away.
3. **Neutral marks, never green or blue.** Fable ruled against Codex's blue: blue on this row means syncing now.
4. **Blank for not watched and unsure.** Fable ruled against Codex's dots and hatching: they turn to mush in 1.6 pt cells, and every night's sleep would look louder than a quiet day.
5. **Stalled broken, failing solid.** Codex's idea, adopted by Fable, for red–orange color blindness.
6. **No "pending" class.** Codex wanted hours with short waits (under 10 minutes) shown apart; Fable folded them into quiet, defined in words as "nothing waiting 10 minutes or more".
7. **Bridging.** A stall's start is found across hours Velum didn't see, but then it is only "Stalls seen since…", with no duration (Codex's objection, adopted by Fable).
8. **The stall note goes on the source line, for stalls of a day or more** (Codex's placement). Fable withdrew a new orange line under the reason because of the owner's row-height rule.
9. **Stalled keeps the owner's definition** (work waiting, nothing uploaded). Fable argued that a file stuck while others upload is the silent failure; it is recorded (`stuckFor`), said in words ("Files waited past 10 minutes on 2 days"), and A3's list and the stuck alert already name the file. The definition can change later without losing data.
10. **"Seen", not "observed"** (Fable), matching the legend's "uploads Velum saw finish".
11. **Uploads are the larger of two floors** (my call, after the live check, not a look or wording question): the tracker's count, and OneDrive's own record. Summing them would count a file twice. The legend now says "uploads Velum saw finish or OneDrive recorded".

**Not done / for the morning**
- **Install** (`./build.sh --install`, after the merge) and let it run: the strip fills in hour by hour. The real file is `~/Library/Application Support/Velum/history.json`.
- **Look at the strip in the real glass panel**, light and dark. Renders draw the glass as a plain background.
- **Hover a strip** for the tooltip, and **turn on VoiceOver** for a row's history sentence. Neither was possible overnight.
- **Decide** whether "Velum wasn't watching for about 2 days of that" should be said on a MacBook that sleeps every night. It is true, and Fable ruled to say it, but it will appear on almost every row's VoiceOver and tooltip.
- **Decide** whether stalls that cross a night should read "Stalls seen since Wednesday" (as built, the consult's honesty rule) or "Stalled for 2 days, since Wednesday" (the card's example). On a MacBook that sleeps, most multi-day stalls will cross a night.

**Changes beyond the card's letter** (small; the owner should confirm them)
1. **"waiting since" names the day when it isn't today** ("waiting since Wed 12:45 AM", "yesterday 2:15 PM"). One line in `Collector.status` and `RelTime.clockWithDay` in `History.swift`. Before, a file waiting two days read "waiting since 12:45 AM", which beside "Stalls seen since Wednesday" contradicted it (Fable's first nice-to-have). The stuck alert's own "waiting since" (`Notifier`, A3's) is unchanged.
2. **OneDrive's own upload record counts toward the hour** (the `reported` field above), because the live check showed the tracker alone misses OneDrive's fastest uploads.

**Follow-ups**
- **OneDrive's own uploads and downloads** are read from the merged Recent list (25 entries), so a burst of more than that between two refreshes is undercounted. For uploads the tracker's count covers bursts, and the larger of the two is used. Downloads are stored but not drawn or spoken.
- **The probe's `UploadTracker` uses the debug build's own defaults** (domain "Velum", as `--dump` already does), not the installed app's.
- **A History-only change** (a stall reaching 24 hours with nothing else changing) redraws the rows at once, but the panel refits its height only at the next status change.
