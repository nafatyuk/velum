# A2 · Problem alerts

**Bucket** A Assurance · **Part one** · **Status: done** November 10, 2026 (`d09e180`); real macOS notifications wait for R1 · **Waits for** C1 · **Runs alongside** A1 · **Feeds** A3, A5, A7

## Brief

A hidden icon can't catch your eye, so Velum should tell you when something goes wrong ([memo](../strategy-memo.md) §2, "Now", row 2, and §3, idea 3). The consultant suggested errors only by default, to keep the noise down.

Read the [campaign rules](../README.md#rules-every-card-follows).

**The idea:** a smoke alarm, not a radio. Silent until something is wrong, one beep per problem, and a word when it's over.

## Work

Alert on four problems:
- uploads failing (with the reason);
- a sync issue OneDrive reports;
- uploads waiting more than 10 minutes;
- OneDrive stopping when the user didn't quit it from Velum.

Each problem settles for 30 seconds first and alerts once. One "resolved" note follows when it clears. A toggle in the ••• menu turns alerts off.

## Done when

Quitting OneDrive from outside Velum gives one "OneDrive stopped" alert, and reopening it gives one "resolved" note, live.

## Ownership and limits

`Notifier.swift`, `Banner.swift`, the notifier's wiring in `AppDelegate.swift`, and the ••• menu's "Notify About Problems".

## Hand-off

**`Notifier`:**
- Problem kinds: failed, issue, stuck, stopped. Episodes are keyed by account, or by `"onedrive"` for OneDrive as a whole.
- Timings: `settle` 30 s, `stuckAfter` 10 min. `userStopGrace` is 120 s after Restart or Quit OneDrive was clicked in Velum (`userStoppedOneDriveAt`).
- Episodes are marked as notified even while alerts are switched off, so switching them on doesn't replay old problems.
- System notifications use the request identifier `velum.<key>`, so a "resolved" note replaces the problem it answers.

**Why there's a banner:**
- macOS refuses notification requests from apps not signed with an Apple-issued certificate. It refuses with no prompt, even while the status reads "not determined". This was verified with two throwaway bundles, one ad-hoc signed and one self-signed (`UNErrorDomain` code 1).
- So `post` falls back to `Banner`: a 300-pt glass panel under the menu bar icon. It hides after 8 s, stays while hovered, opens the panel when clicked, and shows an orange triangle for problems and a green check for resolved.

**Live test, November 10:**
- Quitting OneDrive externally showed "OneDrive stopped" after 35 s (the 30 s settle plus one refresh).
- Reopening it showed "OneDrive: resolved".
- No false per-account alarm appeared while OneDrive started up.

**For R1:** with a Developer ID signature, `requestPermission()` should succeed and the same alerts become real notifications, with no code changes. Check that, and decide with the user whether to keep the "resolved" notes (suggested: keep).

**For C2:** the `"onedrive"` key becomes the provider's id.

**For A3:** the stuck alert's body should name the first file.
