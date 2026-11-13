# A4 · What each light means, and how old it is

**Bucket** A Assurance · **Part one** · **Status: done** November 13 (on `main` at `688874b`) · **Waits for** C2 · **Runs alongside** A3, A7, R2 · **Feeds** P1, C3, S1 (they reuse its reason line and age text)

## Brief

Velum's icon gets a badge for syncing, paused, sync issue, not running and error. "Up to date" and "unknown" both show a plain cloud (`StatusIcon` in `AppDelegate.swift`). In the panel, an unknown account shows a grey question mark and a source label, but not *why* Velum doesn't know or what would let it know. Statuses that come from OneDrive's hourly report show the report's time, but nothing marks a report that is three hours old as old.

The consultant's fourth idea ([memo](../strategy-memo.md) §3): an icon legend and a "why is it unknown?" row, which "turns `.unknown` into trust". The memo also named the permission-free tier's main risk: the up-to-an-hour lag for paused and offline, which the app should answer by showing the status's age (§2, "Now", row 1).

Read the [campaign rules](../README.md#rules-every-card-follows), [C1's](C1-permission-free-tracking.md#hand-off) and [C2's](C2-sync-provider-protocol.md#hand-off) hand-offs, `StatusIcon`, and `AccountRow`, `StatePlatter` and `LidRow` in `PanelView.swift`.

**The idea:** a weather report that says when it was measured and why a station is blank. "No reading since 2 PM: the station is offline" is trustworthy; a blank square is not.

## Work

- **The legend** (`LegendView.swift`). It opens from a "What the Icon Means…" item in the ••• menu, or a small ⓘ beside the summary. It has one line per badge, and says plainly that a plain cloud means "nothing needs you". Velum shows a plain cloud only when it has evidence; otherwise the panel says it can't tell (see the decision below).
- **A "why is it unknown?" line** under any account in `.unknown`. The provider gives the reason and what would end it, for example:
  - "No OneDrive report yet. The next is due by 2:45 PM."
  - "Velum may have missed changes between 1:10 and 1:25 PM (macOS dropped events). It will know again by 1:40 PM."
  - "OneDrive's report is 3 hours old."
  - A7's "OneDrive changed something Velum reads".

  The adapter returns the reason through C2's protocol; the view only shows it.
- **An age on every status.**
  - Each status shows how old its evidence is ("· 4 min ago"). Live sources say "live".
  - A report-based status older than the report interval plus 15 minutes is shown as old: secondary color and the word "old". It is never green, and it never counts as safe for the lid line.
- **VoiceOver** reads the same reasons and ages.

## Done when

- Tests cover:
  - every reason text, from made-up evidence;
  - the age wording;
  - the threshold for old evidence;
  - an old report never making the lid line safe.
- Screenshots in light and dark: the legend, an unknown account with its reason, a stale report.
- The panel's height still fits with two accounts unknown at once.

## Ownership and limits

You own:
- `LegendView.swift`;
- the age text in `AccountRow`;
- the reason strings in the OneDrive adapter;
- one ••• menu line in `PanelView.swift`.

Badge artwork stays as it is unless you decide otherwise (below).

## Decisions for the user

| Decision | Suggested |
|---|---|
| Should "unknown" get its own badge on the menu bar icon (it happens briefly after launch and during gaps) | No badge, but the panel's summary says Velum can't tell; revisit if it confuses |
| Where the legend opens from | The ••• menu, plus an ⓘ beside the summary |

## Hand-off

_Built November 13, 2026, in its own worktree (branch `claude/a4-legend-8be7c5`, cut from `a79be34`), alongside A3 and A7. Codex and the Fable consultant were asked in two rounds; Fable ruled every conflict. Their memos are summarized here, not committed._

**What the owner sees**
- **An ⓘ in the header,** left of refresh, and ••• → **What the Status Means…** open the legend. It is a drill-in that replaces the panel's content, with a back chevron; Esc goes back, and the panel always reopens on the accounts.
- **A reason line** under the headline of any row Velum can't vouch for. It is `.caption` in `.secondary`, never truncated, and runs under the row's buttons to its trailing edge. Notes and the source line now also sit there, so the column beside the buttons holds only the name and headline.
- **An age on every status, in the source line,** attached to the evidence it describes: "Nothing pending · OneDrive report 12 min ago · last change 5 min ago", "iCloud status 4 min ago", "From OneDrive, live", "Nothing pending · Google Drive's queue, live", "Live from macOS". "last activity" became "last change". Fable's reason for keeping the age off the headline: "Up to date · 12 min ago" reads as "became up to date 12 minutes ago".
- **Old evidence.** A timed report older than its interval plus 15 minutes is old: OneDrive's after 75 minutes, iCloud's after 25.
  - An old **healthy** (or unknown-code) report becomes `.unknown`: a grey ?, the headline "Can't tell · last report is old", and the last words moved into the reason. Its source line goes, because the reason names the source and the time.
  - An old **problem** report keeps its state and color, reads "Last reported: Paused · old", and keeps its source line, which carries the age. A problem staying visible isn't assuming OK.
  - A report dated more than 5 minutes in the future is not trusted: "Can't tell", with "dated …, later than this Mac's clock".
- **Headlines:** "Can't tell yet" (no report yet), "Can't tell" (a report that can't say). "No status yet" and "Status unknown" are retired.
- **The summary** never counts unknown as needing attention: "Can't tell for Northwind Traders", "… for A or B", "… for 3 of 4 accounts", and mixed, "Personal: Paused (old report) · Can't tell for Northwind Traders". The tooltip and the icon's VoiceOver label use the same short form for old problems (`AccountStatus.briefHeadline`).
- **Service headings** say "1 up to date · 1 can't tell" when the rest are only unknown.
- **VoiceOver:** the row's label stays "<name>, <headline>". Its value reads the reason, the notes and the source line, with "min" and "hr" spelled out (`Reasons.spoken`). Each legend row is read as its words only.
- **No badge for unknown,** as decided. The plain cloud has two legend rows: evidence, and can't tell.
- **"Safe to close the lid"** now reads "Every change in the watched cloud folders is in the cloud." Codex and Fable both asked for it, since the lid line only knows the watched folders.

**The legend** (`LegendView.swift`). It has three plain sections in one column, which scrolls under a pinned header on short screens. Only the services on this Mac are explained; with none, all of them.
1. **Icons and lights.** One row per menu bar badge, drawn with the real `StatusIcon` artwork next to the real `StatePlatter`. The error row says "(yellow: a warning)". The footnote: "The menu bar shows the worst state of any account."
2. **Sources and age.** macOS (live; the only thing behind the lid line), OneDrive (icon text or the hourly report, old after 75 minutes), iCloud (checked every 10 minutes, old after 25), Google Drive (its queue and pause, live). The minute figures are computed from `OneDriveProvider.reportEvery`, `ICloudProvider.checkInterval` and `ProviderReport.grace`, so they can't drift. The footnote: "An old report is never green. The lid line never uses reports: only live file tracking, its coverage, running apps and live queues."
3. **Recent and notes.** Recent is OneDrive's own history, and only the uploads Velum saw finish for iCloud and Google Drive. Google storage is shared with Gmail and Photos, and orange when almost full (at least 90% used and under 10 GB free) or full (under 100 MB). iCloud storage is orange when full. "Desktop & Documents included" explained. "Storage notes don't change a row's light."

**The protocol** (`Providers/SyncProvider.swift`), for A7, P1, C3 and S1 to reuse:
- `AccountEvidence.unknownReason`: why there is **no** status, and what would end it.
- `ProviderReport.reason`: why **this** report leaves the status unknown or old.
- `ProviderReport.every`: how often a fresh one comes. With `timed`, it decides `isOld(now:)` (past `every + grace`, where `grace` is 15 minutes). Any new timed report must set `every`, or it can never go old.
- The merge (`Collector.status`) copies the reason into `AccountStatus.reason`, and fills `age`, `isOld` and `lastReported`. Its own provider-neutral reasons live in `Reasons.swift`: unrecognized icon words, the coverage gap, not watching yet, a future date, and "Nothing is waiting to upload.". That last one is added to a "can't tell" reason when tracking is complete and nothing is pending, so a grey row under "Safe to close the lid" makes sense.
- `source` keeps its clock time ("OneDrive report, 1:45 PM") and stays free of the age, so the debug log doesn't record a change every minute. The age lives in `detail`.
- `UploadSummary.coverageGapUntil` gives the gap's end; the gap's start is that minus 15 minutes.

**The reasons as shipped:**

| Case | Reason |
|---|---|
| OneDrive, no report yet | "No OneDrive report yet. OneDrive usually writes one about every hour while it runs and this Mac is awake." |
| OneDrive, none an hour after Velum started looking | "No OneDrive report since 1:45 PM, though it writes one about every hour while this Mac is awake." |
| OneDrive, a report with no status line | "OneDrive's report at 1:45 PM had no status Velum can read. Velum keeps looking." |
| OneDrive, unknown code | "OneDrive reported a status Velum doesn't recognize (code 4097). Its next report is due by 2:45 PM." Once that time has passed: "… is overdue." |
| OneDrive, old healthy | "OneDrive last reported “Up to date” at 8:45 PM, 3 hours ago. It reports about hourly while it runs and this Mac is awake." |
| OneDrive, old problem | "This report is 2 hours old. OneDrive may have changed since." |
| OneDrive icon text in unknown words | "Velum doesn't recognize OneDrive's words here." (the words stay as the headline, with "From OneDrive, live") |
| iCloud, first check | "Checking iCloud now. This takes about 15 seconds." |
| iCloud, not caught up | "At 2:45 PM iCloud didn't say it's caught up. Velum checks again at 2:55 PM." (or "… is checking again now.") |
| iCloud, check failed | "iCloud didn't answer the 2:45 PM check. Velum tries again at 2:55 PM." |
| iCloud, old | "iCloud's last answer, at 2:15 PM, is 40 minutes old; it hasn't answered since. …" The "hasn't answered" part appears only after a failed check, since after sleep none may have run. |
| Google Drive, queue unreadable | "Velum can't read Google Drive's queue on this version. Per-file status from macOS still works." |
| Coverage gap (any service) | "Velum may have missed changes here around 1:25 PM. Uploads from before then haven't been verified." It shows under green rows too, because the lid line blames that account. |
| Not watching yet | "Velum has just started watching this account and can't vouch for it yet." |
| Future-dated report | "The last OneDrive report is dated 3:45 AM, later than this Mac's clock. Velum waits for the next one." |

**Changes beyond the card's letter.** They are small, each was recommended by both consultants or ruled by Fable, and **the owner should confirm them**:
1. **Google Drive's unreadable-queue fallback is no longer green.** P3 made it "Up to date · Google Drive running". A running process is no evidence of being caught up, and a legend that says "green only with evidence" can't ship beside it. It is now `.unknown`, "Can't tell", with the reason above. `GoogleDriveProvider.runningReport` is the only change; waiting, uploading and failing files still show. A7 was told in the shared notes.
2. **Alerts ignore old problem reports** (`Notifier`, two lines). An old "Sync issue", such as one from before the Mac slept, neither alerts nor sends a false "resolved" when it merely ages. A fresh report decides either way.
3. **Periodic reports never set `workPending`.** Only live evidence (Google Drive's queue) can hold the lid at "still syncing". No timed report produces `.syncing` today, so nothing changes now; the invariant is written down.
4. **A full iCloud note turns orange** (`notesNeedAttention`), as the legend says. It still doesn't set `storageFull`, so there is no iCloud storage alert; see the follow-ups.
5. **README:** the status-line examples, the Google queue line and the "no evidence" paragraph now match. G1 still owns the page.

**Tests:** 118 (86 before), all passing with `Scripts/test.sh`. The new file is `Tests/VelumTests/LegendTests.swift`, all with made-up evidence. It covers:
- every reason text, including the overdue switch at its boundary;
- the age wording and the spoken form;
- the old threshold at 75 and 25 minutes, ±1 s;
- the old-healthy, old-problem, old-unknown and future cases, and that every old report is never `.ok`;
- an old pause not relabelling waiting files;
- the lid line: an old report is never what makes it safe, and gives the same verdict as no report at all;
- the summary;
- the legend's states, sources and thresholds, pinned against `GoogleStorage`;
- an old sync issue neither alerting nor resolving.

Six older expectations changed with the wording: "No status yet", "Status unknown", Google's queue label, and the unreadable-queue test.

**Screenshots** (light and dark: the legend, two accounts unknown, a stale report and a gap) are in the session's scratchpad, not the repo, because the repo is public. They come from made-up data: `Velum --render-panel out.png --sample healthy|unknown|old [--legend] [--dark]` (`SampleData.swift`) runs fixture evidence through the real merge.
- Heights: 677 pt healthy, 731 pt with two accounts unknown, 759 pt with the old sample. Past the screen's height the panel scrolls, as before.
- The legend is 748 pt; on a short screen it scrolls under its pinned header (checked with `--max-height 480`).

**Checked live, read-only:** `Velum --dump` on this Mac showed the new source lines with real ages ("OneDrive report 47 min ago", "iCloud status just now", "Google Drive's queue, live") and no false reasons. `--dump` now prints `why:` lines.

**Not done:**
- No `./build.sh --install`, so the installed app is unchanged.
- The ⓘ, the ••• item, Back and Esc were not clicked in the real menu bar panel; only renders and tests cover them.

**Follow-ups:**
- **The coverage gap ends on a timer** (Codex's catch). `UploadTracker` clears a gap 15 minutes after the last dropped event without re-checking the files it may have missed. The lid line can therefore return to "safe" with a missed change unverified. The reason no longer promises when Velum can vouch again; a reconciling scan of the gap's folders is the real fix (C1/A1 territory).
- **iCloud full storage sets no `storageFull`,** so it gets no storage alert, unlike Google Drive (P1).
- **A3 and A7 merge notes:**
  - `AccountRow` was restructured: the top line, plus a `lines` block under the buttons.
  - `PanelView`'s body is now `main` or `LegendView`.
  - `Notifier` changed two lines (the `.error` condition and the resolution loop).
  - A7 should not restore Google Drive's green fallback.
  - **A7 adds its own field** (its message, November 13): `AccountEvidence.compatibilityNote`, copied to `AccountStatus.compatibilityNote`, set when a client changed something Velum reads. A7 also appends it to `notes` until this reason line exists. At merge, wire it into the reason line in `Collector.status`, just before the "Nothing is waiting to upload." step, and drop A7's `notes` append:

    ```swift
    if let note = account.compatibilityNote {
        // The report was dropped on purpose: say why, instead of the generic "no report yet".
        if state == .unknown { reason = note; reasonReplacesSource = true }
        else { reason = [note, reason].compactMap { $0 }.joined(separator: " ") }
    }
    ```

    A7 also adds a line inside `Snapshot.lidVerdict`, before the `blind` check. A4 changed only the doc comment above `lidVerdict`.
- **README's progress table** still says A4 is planned. It was left alone so the parallel cards' rows merge cleanly.

### What changed since this card was written (November 12)

- **Three services, three kinds of account-wide evidence,** so the legend and the "why unknown?" line must explain each:
  - OneDrive's hourly report (up to an hour old);
  - iCloud's `brctl status` (every 10 minutes);
  - Google Drive's own queue (live), with "Google Drive running" when the queue can't be read.
- **Recent is partial for two of them.** For iCloud and Google Drive it shows only uploads Velum saw finish while it was running (Fable's risk from P1).
- **Notes that need explaining:** storage ("214 GB free of 400 GB"; orange when almost full or full; storage never changes a row's state) and "Desktop & Documents included".
- **"Paused" now exists for Google Drive** (its `user-paused` file) as well as OneDrive.
