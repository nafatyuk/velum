# A5 · A warning before sleep or shutdown

**Bucket** A Assurance · **Part two** · **Status: done** (unit-tested; the live lid check waits for the owner) · **Waits for** C2, A1, A2 (a real notification needs R1) · **Runs alongside** P1, C3, T1, A6, S2 · **Feeds** nothing

## Brief

The lid line (A1) answers the question if you look. This card covers the times you don't: you choose Sleep or Shut Down, or close the lid, with files still on their way up. The consultant's sixth idea ([memo](../strategy-memo.md) §3, idea 6): "notify if sleep is requested with uploads pending".

**Find out before building:** what macOS lets an ordinary app do at each moment.
- `NSWorkspace.willSleepNotification` arrives, but sleep goes ahead; an app can't delay it. Only idle sleep can be refused, through IOKit power callbacks.
- Logout and shutdown send `willPowerOffNotification`, and running apps are asked to quit.
- A notification posted as the Mac falls asleep may only be seen at wake.

The design follows what's possible. Your decision below is "warn only, never hold up sleep".

Read the [campaign rules](../README.md#rules-every-card-follows), and [A1's](A1-safe-to-close-the-lid.md#hand-off) and [A2's](A2-problem-alerts.md#hand-off) hand-offs.

**The idea:** the "you left your lights on" chime. It doesn't stop you leaving the car; it makes sure you know.

## Work

- **`SleepGuard.swift`** listens for will-sleep, did-wake and will-power-off.
- **At sleep:** record the lid verdict and the pending count.
- **At wake:** if files were pending at sleep, one note through A2's notifier, either:
  - "3 files weren't in the cloud when your Mac slept. They've uploaded since." (resolved), or
  - "3 files still aren't in the cloud." (a problem, which follows A2's rules from then on).
- **At logout or shutdown, with files pending:** post the alert at once. "3 files aren't in the cloud yet. They'll upload the next time OneDrive runs."
- **No noise:** it respects the alerts toggle, never alerts when everything was safe, and never blocks or delays sleep or shutdown.

## Done when

- Tests with stand-in notifications and a fake clock cover each moment and each outcome.
- Live, with the user (their Mac and their lid):
  1. With a probe pending (their yes), close the lid briefly.
  2. At wake, the right note appears.
  3. The probe is deleted once it has settled.

## Ownership and limits

You own `SleepGuard.swift`, plus one line in `AppDelegate.swift` that starts it. Change no power settings.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Warn only, or also hold off idle sleep while uploads finish | Warn only; never hold up sleep or shutdown |

## Hand-off

Built overnight, November 13, 2026, in a worktree session running alongside T1, A6, S2 and G2. Your decision was applied: **warn only**. Nothing holds up or delays sleep or shutdown, and no power setting is touched.

### What macOS 27 lets an ordinary app do (checked first)

Sources: the macOS 27.2 SDK headers (`NSWorkspace.h`, `IOPMLib.h`, `CGSession.h`), Apple's QA1340, and Apple's developer forums. Apple's documentation of `willSleepNotification` says a slow observer can delay sleep.

| Moment | What an app gets | What Velum does |
|---|---|---|
| Will sleep (lid, Apple menu, idle) | Notice only; sleep goes ahead. A slow handler can hold it up to 30 s. Only idle sleep can be refused (IOKit `kIOMessageCanSystemSleep`), and Velum doesn't. | Records what isn't in the cloud from what it already holds (no File Provider calls) and returns. |
| Did wake | Comes after a full wake. The network and the sync apps need some seconds more. The screen is usually locked. | Checks with every refresh; speaks only once the screen is unlocked. |
| Will power off (log out, restart, shut down) | Comes just before apps are asked to quit, about a second later. `extendPowerOffBy:` "is currently not implemented". `IORegisterForSystemPower` gives no shutdown notice. | Alerts at once, and saves the list so the next launch can say whether it made it. |

Two findings shaped the design:
- **A note posted as the Mac sleeps isn't seen**, so the news waits for the wake.
- **Velum's own banner (unsigned builds, A2) can't show over the lock screen**, and it hides after 8 s. So the wake note waits for the unlock. The lock state comes from `CGSessionCopyCurrentDictionary()` (`CGSSessionScreenIsLocked`, present on macOS 27.3); if it can't be read, the note isn't held back.

At shutdown the banner is on screen for well under a second. That's why the list is saved and checked again at the next launch.

### What was built

**`SleepGuard.swift`** (new):
- **At sleep:** records every file on its way up, by path, from A3's listing (`UploadTracker.pending`, uncapped). Waiting and uploading files count; failing files don't (A2 has reported them, and they'd come back at every wake). It also records any account whose service has work queued that Velum can't count (`workPending`: Google Drive's own queue, the lid line's "still syncing"). The lid verdict goes to the debug log. Nothing recorded means nothing is said at wake.
- **At wake:** checks with every refresh. Each followed file ends up as one of:
  - **in the cloud**, only when macOS's own upload flag says so (`ubiquitousItemIsUploaded`). Leaving the list isn't enough (Codex and Fable): a deleted or moved file also leaves it.
  - **still waiting**, or **uploading**;
  - **waiting on a stopped app** (A2's "stopped" alert speaks for it);
  - **can't vouch** (off the list, no flag);
  - **dropped**: failing now (A2's alert), deleted or moved, or its account gone.

  A queue is "caught up" only on the service's own live "Up to date" (an empty, readable Google Drive queue), never on an old report.
- **The notes:**
  - **Resolved:** posted as soon as everything followed has an answer and something is in the cloud.
  - **Problem:** posted once nothing has moved or cleared for 2 minutes after unlock. A file that's uploading, or a count that's falling, waits up to A2's 10-minute stuck threshold.
  - **Follow-up:** one follow-up to the problem note, when everything it named is in the cloud, under the same identifier (`velum.sleep`), so it replaces the problem note. If a named file went another way (deleted, failing), there's no follow-up: gone isn't resolved (A2's rule).
- **Repeated sleeps merge** into one record. A file already in a problem note isn't named again at the next wake.
- **At log out, restart or shut down:** an alert at once. The record, merged with anything still open, is saved in Velum's defaults (`sleepGuardWatch`).
  - **The next launch** runs the same check, with "shut down or logged out" wording.
  - **A record saved at sleep is also picked up at launch**, so a Mac that ran flat while asleep, or a Velum quit mid-check, still gets its note (Fable).
  - **A log out that's still not done after 2 minutes** was cancelled. The record is dropped quietly.
- **The alerts toggle and the debug log:** with alerts off nothing is shown, but the episode counts as said (A2's rule). The debug log gets `[sleep]` lines with counts and service names, never file names. Problem notes give the notifier a name-free twin to log.

**Shared files, each edit on its own lines:**
- `AppDelegate.swift`: one line, right after `store.onRefresh` is set. `SleepGuard.shared.start(store:notifier:)` chains onto `onRefresh`, so each refresh runs the guard's check first and then the notifier's update, on the same snapshot.
- `Model.swift`: `Store.pendingFiles()`, two lines after `lidVerdict`. It isn't in `refresh`, where T1 and A6 add their hooks.
- `Notifier.swift` (not on the shared list, but A2's):
  - the `sleepGuard` cover property;
  - `heldBySleepGuard` added to the two existing conditions;
  - a `note(...)` entry point and the helper, at the end of the instance methods.
- `README.md`: one item in "What you get" and one in the Alerts list.

**Not saying it twice (`SleepGuardCover`).** While the guard follows files, A2's alerts wait in two cases:
- an account's stuck alert, but only while every file it's stuck on is one the guard follows. A new file stuck in the same account still alerts (Codex and Fable both asked for that rather than an account-wide mute);
- a followed queue's "changes are stuck" alert.

So does those alerts' "resolved", while the guard is following that account. When the guard ends with a note, the cover stays for that refresh, so A2 doesn't add its own "resolved". When it ends silently, the cover clears at once, so A2's "resolved" can still go out.

### Look and wording

Codex and the Fable consultant answered the same brief separately. Fable decided the conflicts, as on A3.

| Note | Title | Body |
|---|---|---|
| Wake, resolved | Uploaded after sleep | "3 files weren’t in the cloud when your Mac slept. They’re there now." / "1 file wasn’t … It’s there now." |
| Wake, problem | Still not in the cloud | "Report.docx and 2 more haven’t uploaded since your Mac woke." / "Report.docx hasn’t uploaded since your Mac woke." |
| Follow-up | Uploads: resolved | "The files from before your Mac slept are in the cloud now." |
| Shutdown | Not in the cloud yet | "3 files aren’t in the cloud yet. They’ll upload the next time OneDrive runs." Two services: "… OneDrive and Google Drive run." With iCloud, or three services: "… after you log in again." |
| Next launch | Uploaded since shutdown / Still not in the cloud | "… when you last shut down or logged out. They’re there now." / "… haven’t uploaded since you last shut down or logged out." |
| Google Drive queue only | Google Drive caught up / Google Drive is still syncing / Google Drive: resolved / Google Drive hasn’t finished | "Google Drive was still syncing changes when your Mac slept. It has caught up." / "It hasn’t finished the changes it had queued when your Mac slept." / "Some changes aren’t in the cloud yet. Google Drive will carry on the next time it runs." |

Decisions, with both views:
- **"They’re there now"** over the card's "They’ve uploaded since". Fable: the singular "It’s uploaded since" reads badly. Codex's "were waiting before sleep … now in the cloud" lost to it.
- **Name a file in problem notes only.** Fable: that's where the user can act, and it matches A3's stuck alert. Codex wanted counts everywhere. Resolved and shutdown notes count only.
- **The wait:** 2 minutes from the unlock, with up to 10 while something is moving (Fable). Codex wanted 2 minutes from the wake, shown at unlock. Fable's way never alerts during a large upload.
- **Shutdown keeps the card's "They’ll upload the next time OneDrive runs"** (Fable). Codex objected that it promises an outcome and suggested "Check Cloud Sync when you return." This one is yours to overrule.
- **Counted files plus a queue:** the counted wording, with "resolved" held until the queue is empty too (Fable). Codex wanted "Google Drive also has changes queued."
- **When nothing can be confirmed** (a file left the list with no upload flag): say nothing. Codex proposed an "Uploads unconfirmed" note; Fable's line was to say nothing when there's nothing true to say.
- **Declined: Fable's "skip the resolved note after a sleep under a minute".** Codex didn't ask for it. Your live check ("close the lid briefly") would then show nothing. And when the guard stays silent, A2's own "resolved" for the same files can be lost.

### Tests

`SleepGuardTests.swift`: 29 tests. They use a fake clock, NSWorkspace's three notifications posted on a private `NotificationCenter`, a stand-in lock screen and upload flag, and made-up files under `/Users/test`. They cover:
- **Each moment:** sleep with nothing pending; resolved after unlock; the problem after 2 quiet minutes, then its one follow-up; singular wording; an upload in progress waiting up to 10 minutes; progress restarting the wait; a locked screen holding the note, with the wait starting at unlock; the shutdown alert at once, then the next launch's resolved or problem note; a Mac that ran flat asleep; a cancelled log out; alerts off.
- **Hand-overs:** failing at sleep; failing after wake; deleted or moved files; off the list without the flag; a stopped app, and one that restarts; a second sleep merging without repeating the problem.
- **Google Drive's queue:** caught up; still busy at 10 minutes, then resolved; unreadable (A7) is never "caught up".
- **Wording:** shutdown with one service, two, and with iCloud; a queue only; counted plus queued; the log line naming no file.
- **With the real `Notifier`:**
  - stuck and alerted before sleep, uploaded after wake: one note (the guard's), not A2's "resolved" too;
  - A2's stuck alert stays quiet while the guard covers the same file;
  - a new stuck file in the same account still alerts;
  - A2 is unchanged without the guard.

The cap is injected (`stuckAfter:`), because A3's `thresholdOverride` test briefly sets the shared `stuckAfterSeconds` while other suites run.

**The run** (`Scripts/test.sh`, through the shared queue): 193 tests, 189 passed, and all 29 new ones passed, with no compiler warnings in the files this card touched. The 4 failures were already on the base (`f07c78d`): stale wording from the wave 2 merge ("No status yet" / "Status unknown" where A4 now says "Can’t tell yet" / "Can’t tell"). They're fixed on `main` at `3c3e311` and weren't touched here.

### Not checked live (needs your lid)

Nothing here was run against a real sleep: a sleep would have stopped the overnight session. To check by hand:
1. Run this branch's build. Either install it (`./build.sh --install`, your yes), or quit the installed Velum and open the build, as A3 did.
2. Turn on ••• → Debug Logging.
3. **Problem, then follow-up.**
   - Pause OneDrive from its own menu. Save `velum-test-<time>.txt` at the top of the Personal OneDrive (your yes). The lid line should read "Wait before closing the lid".
   - Don't use Wi-Fi off for this. A3's live check found that a disconnected OneDrive marks new files as failing ("couldn’t connect"); failing files are A2's, so A5 would rightly stay silent.
   - Close the lid for at least a minute. Open it and unlock.
   - About 2 minutes later: "Still not in the cloud · velum-test-….txt hasn’t uploaded since your Mac woke."
   - Resume OneDrive: "Uploads: resolved" should follow once the probe uploads.
4. **Resolved.** As in step 3, but resume OneDrive within 2 minutes of unlocking: "Uploaded after sleep · 1 file wasn’t in the cloud when your Mac slept. It’s there now."
5. **Shutdown.**
   - Optionally, with OneDrive paused and a probe pending, choose Restart. Note whether the "Not in the cloud yet" banner is readable at all.
   - After logging in, OneDrive starts unpaused (worth noting if it doesn't). Then: "Uploaded since shutdown", or after 2 quiet minutes "Still not in the cloud".
6. **The log.** The `[sleep]` lines in `~/Library/Logs/Velum/Velum.log` show the lid verdict and the counts, and no file names.
7. **Clean up.** Delete each probe about 75 s after it shows as uploaded, then turn Debug Logging back off if you like.

### For later cards

- **S2 (diagnostics):** Velum's defaults now hold `sleepGuardWatch`, which carries file paths like `pendingUploads` does. Redact both.
- **R1:** with a Developer ID signature, the shutdown alert becomes a real notification that stays in Notification Center. The next-launch note is then a second word, not the only one. Decide then whether to keep both (suggested: keep).
- **T1:** `velumctl` could show the open record (`SleepGuard.shared.watch`), if that's useful.
- **The check's cost:** while a record is open it reads the tracker's whole pending list on each refresh, under the tracker's lock. Files that have left the list get at most 50 File Provider lookups per refresh, on the main thread, each cached once it reads uploaded. That's fine for tens of files; a record of thousands would want it moved off the main thread.
- **Renamed files:** the old path counts as moved (dropped). The new path is a new change, not followed, so a rename while asleep ends silently.
