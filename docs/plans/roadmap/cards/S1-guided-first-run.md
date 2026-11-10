# S1 · A guided first run

**Bucket** S Support · **Part two** · **Status: planned** · **Waits for** C3, P1 · **Runs alongside** G2, R3 · **Feeds** G1

## Brief

Velum's README asks a new user to do two things by hand.
- **Hide OneDrive's own icons:** System Settings → Menu Bar → Allow in the Menu Bar.
- **Find Velum's icon.** macOS 27 puts new menu bar icons in its hidden section, and on a notched display they can sit behind the notch.

Velum already places itself at OneDrive's old position through its own `NSStatusItem Preferred Position` default. Nothing in the app explains any of this, or shows which clouds it found. The consultant's eighth idea: guided onboarding that deep-links to the Menu Bar settings and detects the vendors' icons ([memo](../strategy-memo.md) §3, idea 8).

Read the [campaign rules](../README.md#rules-every-card-follows) (system settings are the user's: Velum may open the pane, never change it), the README's "First run", `SettingsPane` and `openSystemSettings` in `AppDelegate.swift`, and C3's and P1's hand-offs.

**The idea:** the welcome card in a hotel room. Here's what's in the room, here's the one switch you'll want, and here's where the light is.

## Work

- **Find out first:**
  1. Can Velum tell which vendor icons are still in the menu bar, without a permission? Candidates: status-item windows listed by owner name, which needs no Screen Recording permission for owner names; or Accessibility, only if already granted. Verify on macOS 27 with OneDrive's icons hidden and then shown. The user toggles them.
  2. Which URL opens System Settings → Menu Bar on macOS 27?
- **`FirstRunView.swift`,** shown in the panel on first launch, and again from the ••• menu's "Setup…":
  - The clouds Velum found ("OneDrive: 2 accounts · iCloud Drive · Dropbox (beta)").
  - Which of them still show their own icons, with an Open Menu Bar Settings button.
  - Where Velum's own icon is, and how to ⌘-drag it if it landed in the hidden section.
  - Open at Login, already on, with its switch.
  - Alerts: macOS's notification prompt after R1; the banner explained before it.
- **Done when the user says so.** "Done" dismisses it for good, and it never nags.
- Follows the panel's look; light and dark.

## Done when

- Tests: the found-clouds summary from made-up accounts; first-launch state.
- Screenshots, light and dark, with real and made-up clouds.
- With the user, who toggles their own settings: the icon detection is right with OneDrive's icons shown and hidden, and the settings button opens the right pane.

## Ownership and limits

You own `FirstRunView.swift`, its first-launch flag, and one ••• menu line. Never write any system preference, not even "helpfully".

## Hand-off

_Not started._
