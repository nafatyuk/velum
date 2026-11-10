# A5 · A warning before sleep or shutdown

**Bucket** A Assurance · **Part two** · **Status: planned** · **Waits for** C2, A1, A2 (a real notification needs R1) · **Runs alongside** P1, C3, T1, A6, S2 · **Feeds** nothing

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

_Not started._
