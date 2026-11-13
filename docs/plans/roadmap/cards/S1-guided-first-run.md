# S1 · A guided first run

**Bucket** S Support · **Part two** · **Status: built; live check waits for the owner** · **Waits for** C3, P1 · **Runs alongside** G2, R3 · **Feeds** G1

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

**Built** November 13, 2026, overnight, in its own worktree (not merged, not installed). The live check with the owner toggling his own icons is still to do: see [For the owner](#for-the-owner).

### Answers to "find out first" (this Mac, macOS 27.3, no permission prompt)

1. **Which vendor icons are in the menu bar.**
   - **Window lists can't tell.** On macOS 27.3 a status item is no longer a window of its own app. `CGWindowListCopyWindowInfo` lists no window at all for Velum, although its icon is in the menu bar; the bar is one Window Server "Menubar" window plus MenuBarAgent's. Owner names come without Screen Recording, but there is nothing to find by them. (The shell this was checked from may hold Screen Recording, since it also saw window titles; it doesn't matter, as the approach fails either way.)
   - **Accessibility isn't used.** An app already running when its icon is switched off keeps its menu extras in Accessibility (verified on 27.2–27.3 earlier), so they would read as shown. Velum's own Accessibility grant is never needed.
   - **macOS's own list is.** System Settings → Menu Bar → Allow in the Menu Bar is stored as `TrackedApplications`, JSON data, in the current host's `com.apple.controlcenter.systemmenubaritems` preferences: `{"<bundle ID>": {"lastKnownLocalizedName": …, "rawBundleId": …, "isAllowed": true}}`. The settings pane's binary names `TrackedApplications` and `_isAllowed`; MenuBarAgent logs "Creating status item %s, isAllowed: %d". Velum reads it with `CFPreferencesCopyValue`, which needs no permission and writes nothing. Here it lists 13 apps, OneDrive allowed. Google Drive and Velum have no entry: an app that was never switched has none, and both icons show, so no entry means macOS's default, allowed.
2. **The URL.** The existing `x-apple.systempreferences:com.apple.ControlCenter-Settings.extension` is right. On 27.3 that extension's display name is "Menu Bar", it holds "Allow in the Menu Bar", and its Info.plist sets `allowsXAppleSystemPreferencesURLScheme`. Opening it was not tried tonight (nothing on the owner's screen); it is in the morning check.

### What was built

- **`Sources/Velum/FirstRunView.swift`**, shown in the panel in place of the accounts, like the legend:
  - "Clouds Velum found": a line per service with its count, and under it that app's menu bar setting;
  - an advice sentence and **Open Menu Bar Settings** (the existing `openMenuBarSettings` action);
  - "Velum's icon": the cloud, where it is, «, and ⌘-drag;
  - "Startup and alerts": **Open at Login** and **Notify About Problems** switches (the existing actions), and how alerts arrive (Velum's banner, or macOS notifications once the build is signed);
  - a pinned footer: "Find this again in ••• → Setup…" and **Done**.
- **Detection** (`MenuBarAllowList`, `VendorIcon`): an entry `false` reads "turned off"; `true`, or no entry for OneDrive or Google Drive (both checked to draw icons), reads "allowed". A beta-tier app with no entry, an app Velum can't identify, an entry without a real boolean, or a list that can't be read or parsed reads "can't", never a guess. Velum's own entry switched off gets the one orange line. Running state comes from the snapshot (OneDrive, Google Drive) or `NSRunningApplication` (a beta app Velum can name).
- **When it shows** (`FirstRun`): only at a true first launch, when Velum's defaults have no `loginItemConfigured` (every install writes it at its first launch, since the first commit). That launch opens the panel by itself once, 1.5 s in. Closing the panel or Done ends it (`firstRunDone`). The exception is a close caused by its own Open Menu Bar Settings: it then shows once more at the next opening, with the switches read again (`firstRunPending`). ••• → **Setup…** shows it any time. It never opens itself again, never alerts and never badges. Only Velum's own defaults are written.
- **Checking it:** `Velum --render-first-run out.png [--dark] [--sample <name>] [--icons on|mixed|off|own-off|unreadable|live] [--stopped] [--no-clouds] [--max-height N]`. With `--sample`, the clouds and the list are made up. `--icons live` (the default without `--sample`) reads this Mac's list and prints it. `Velum --dump` gains two lines: where the first run stands with the clouds it would list, and each app's menu bar setting.
- **Shared files, on their own lines:**
  - `Model.swift`: `Store.showingFirstRun`;
  - `PanelView.swift`: the view's branch and the ••• menu's Setup…;
  - `AppDelegate.swift`: one line at launch (before `LoginItem.enableOnFirstLaunch`), one when the panel opens, one when it closes;
  - `Entry.swift`: the render flag and the dump lines;
  - `README.md`: a paragraph under "First run", and Google Drive in step 1.

  Nothing was taken from Crisp, so `THIRD_PARTY_NOTICES.md` is unchanged.

### Decisions

Codex and the Fable consultant were each given the renders, light and dark; Fable ruled the conflicts.

| Decision | Made | Codex | Fable |
|---|---|---|---|
| Who sees it | **A true first launch only**, judged from Velum's existing `loginItemConfigured`. Existing installs, the owner's included, reach it from ••• → Setup… | A: "introducing onboarding doesn't make an existing user new" | A: opening by itself after an update is the nag the card forbids |
| How it ends | **Done or any close of the panel**, except a close caused by its own Open Menu Bar Settings, after which it shows once more | until Done: Settings itself closes the panel, so a close can't mean consent | a close is done; accepted the Settings exception as the reconciliation |
| "No entry" for OneDrive and Google Drive | **Allowed**, worded as the setting ("allowed"), never as "shows". Can't tell everywhere else | acceptable for apps known to draw icons; it proves the setting, not visibility | acceptable; record that it rests on one Mac on 27.3 |
| The cloud lines | **Codex's set**, plus Fable's "· app isn't running": "Menu bar icons allowed, one per account", "Menu bar icon allowed", "… turned off", "No menu bar icon", "Can't read its menu bar setting", "Can't tell whether this app has a menu bar icon", "Can't identify the app syncing this folder", "App isn't running" | this set | ruled for it, with the amendment |
| Advice | "You can hide the menu bar icons for … under Allow in the Menu Bar. Hiding them doesn't stop syncing." / "Velum can't tell whether … show a menu bar icon. If you see one, you can hide it under Allow in the Menu Bar." / "Menu bar icons are turned off for the apps above." | drop "Velum shows the same status" (it overclaims) | ruled for Codex's direction, reworded |
| Velum's icon | "Velum is this cloud in the menu bar. If you can't see it, macOS may have put it with the hidden icons: click « in the menu bar to show them. To move the cloud, hold ⌘ and drag it." | "the double-chevron button", pending a check | first no glyph; then « given the README and the owner's 27.3 notes |
| Alerts | "Alerts show as a banner under Velum's icon. This copy of Velum isn't signed for macOS notifications." | no reason given | keep the reason: the switch is called Notify About Problems |
| Look | One prominent button: Open Menu Bar Settings while something can be switched off, Done otherwise. Orange only for Velum's own icon switched off, with a warning glyph. Footer pinned and `.secondary`. Counts `.tertiary`, as in the panel. Switches `.mini` | one prominent; footer pinned and readable; counts `.secondary` | one prominent, orange only there; counts stay `.tertiary`; withdrew a switch-size change |
| Kept as written | "Welcome to Velum", "One icon for every cloud on this Mac.", "Clouds Velum found", "None yet", "Find this again in ••• → Setup…" | "One icon for your cloud sync.", "Reopen from ••• → Setup…", "No cloud accounts found yet" | keep |

Also decided here, outside the review:
- **No Return key on Done.** Pressing Return by accident would end it for good.
- **"None of these has a menu bar icon of its own."** for a Mac with only iCloud Drive. Neither consultant saw this sentence.

### Checked

- **Tests:** `Scripts/test.sh` through the shared queue: 305 tests in 60 suites pass. Fifteen are new, in `FirstRunTests.swift`:
  - first-launch state and closing;
  - parsing the list, garbage included;
  - the icon state never guessing;
  - the found-clouds summary from made-up accounts;
  - every line and advice sentence;
  - stopped apps;
  - the dump lines.

  `./build.sh` built, with no new warnings.
- **Renders, made-up data, light and dark:** on, mixed, off, list unreadable, beta, Velum's own icon off, apps stopped, no clouds, and a short screen (the middle scrolls under the pinned header and footer).
- **This Mac, read-only:** the list read inside Velum matches the file (13 apps; OneDrive allowed; Google Drive and Velum not listed, both running). A live render shows "OneDrive · 2 accounts · Menu bar icons allowed, one per account", "iCloud Drive · No menu bar icon", "Google Drive · 1 account · Menu bar icon allowed". The installed app's defaults gained no first-run key. Images stay outside the repository.
- **Found on the way:** a glass button (`.glass`, `.glassProminent`) makes an offscreen `cacheDisplay` render come out entirely blank. Renders therefore draw bordered stand-ins (`--glass-buttons` keeps glass). The same holds for `--render-panel` whenever the panel's own glass buttons show (Start at a stopped service's heading, the Accessibility tip's Restart).

### Not checked tonight

- The real panel: the glass buttons, the switches and the first-launch opening. Nothing was put on screen.
- That the button opens the right pane.
- That a toggle in System Settings shows up when the panel reopens. `CFPreferencesCopyValue` may serve a cached copy inside a long-running app. If it does, read the ByHost file directly.
- That switching Google Drive off adds its entry, which is the "no entry = allowed" assumption.
- Where the panel lands when Velum's icon is hidden or behind the notch at a true first launch (Fable's flag).
- That « is macOS 27.3's control for the hidden icons.

### For the owner

1. **Install** (your call; the supervisor merges first): `./build.sh --install`. Your install is an existing one, so the first run won't open by itself.
2. **Open it:** Velum's ••• → **Setup…**. Expect OneDrive "Menu bar icons allowed, one per account" and Google Drive "Menu bar icon allowed", with a blue Open Menu Bar Settings.
3. **Click Open Menu Bar Settings.** System Settings should open on Menu Bar, with Allow in the Menu Bar on it.
4. **Switch OneDrive off there, then reopen Velum's panel.** Setup shows once more; OneDrive should now read "Menu bar icons turned off". From Terminal instead: `build/Velum.app/Contents/MacOS/Velum --dump | grep -A1 "First run"`.
5. **Switch Google Drive off,** reopen, and check it reads "Menu bar icon turned off". Then turn on again whatever you want to keep.
6. **Look at « in the text:** is that what your menu bar shows for the hidden icons? If not, say what it is.
7. **Close the panel.** Setup shouldn't come back by itself. ••• → Setup… still works.
8. **Optional:** the first-launch opening can only be seen on a Mac or user account where Velum has never run. Not urgent.

### What changed since this card was written (November 12)

- **The owner hit this card's problem on November 12:** after Google Drive was added, its own menu bar icon was still showing, and only System Settings can hide another app's icon. Velum's ••• menu now has **Menu Bar Settings…** (System Settings → Menu Bar), so a first run should point to it for every service whose app draws an icon: OneDrive (one per account) and Google Drive (one for all accounts). iCloud Drive draws none.
- "The clouds Velum found" now means OneDrive, iCloud Drive and Google Drive, discovered at run time (see P3's plug-and-play section).
