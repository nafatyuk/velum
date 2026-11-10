# Velum

**Every OneDrive account, one cloud in your menu bar.**

OneDrive for Mac draws a separate menu bar icon for every account you sign in to, so a personal account
plus a work or school account means two clouds, three accounts means three. Hiding them (in System
Settings or with a menu bar manager) also hides whether your files are synced.

Velum merges them instead of hiding them: one native menu bar icon and one Liquid Glass panel that show
every account's sync status, recent activity across all of them, and quick ways into each account.

*A velum is a thin veil of cloud that stretches across several separate clouds and joins them.*

## What you get

- **One icon.** A cloud that gets a small badge when any account is syncing, paused, has a sync issue,
  or isn't running.
- **Every account at a glance.** OneDrive's own status wording for each account ("Backed up and
  synced", "Uploading file (58%)"), when it last did something, and how many files it holds.
- **Recent activity, merged.** Uploads, downloads, deletes and moves from all accounts in one list.
  Click a file to show it in Finder.
- **Quick actions.** Open an account's folder or its web view, its recycle bin (work and school
  accounts), storage page, restart or quit OneDrive, open at login.

Velum never modifies OneDrive's files or settings and makes no network connections. The only things it
does to OneDrive are the Restart and Quit OneDrive commands you click.

## Requirements

- macOS 26 or later (built and tested on macOS 27).
- OneDrive for Mac, signed in to one or more accounts (tested with OneDrive 26.204).
- Xcode or the Command Line Tools (`xcode-select --install`) to build it.

## Install

Velum is distributed as source for now. Build and install it with:

```sh
git clone https://github.com/nafatyuk/velum.git
cd velum
./build.sh --install
```

This builds a release binary, wraps it in `Velum.app`, signs it, copies it to `~/Applications` and
launches it. Signing uses a self-signed identity that `Scripts/sign.sh` creates on first run in its own
keychain file under `~/Library/Application Support/Velum/Signing/` (not your login keychain). Because
that signature stays the same across builds, macOS keeps Velum's Accessibility permission when you
rebuild.

## First run

1. **Hide OneDrive's own icons.** System Settings → Menu Bar → Allow in the Menu Bar → turn **OneDrive**
   off. OneDrive keeps syncing; only its icons go away.
2. **Find Velum's icon.** macOS 27 puts new menu bar icons in its hidden section (behind the « control).
   ⌘-drag Velum's cloud to where you want it.
3. **Optional: allow Accessibility** for exact status. Click Velum's cloud, then **Turn On…**, and switch
   Velum on in Privacy & Security → Accessibility. Without it Velum still works, using the sources
   listed below.

## What Velum reads

With Accessibility allowed, Velum reads one thing through it: the title of OneDrive's own menu bar
items, which is OneDrive's status text. Velum doesn't read other apps' windows, your screen or your
keystrokes.

OneDrive only exposes that text while its menu bar items exist. If OneDrive starts with its icons
switched off in System Settings, it never creates them, so there is nothing to read and Velum uses the
other sources below. Keeping exact status working across restarts is being worked on.

Everything else comes from files OneDrive already keeps on your Mac, opened read-only:

| Source | Used for |
|---|---|
| OneDrive's menu bar item titles (Accessibility) | exact live status |
| File Provider progress for each OneDrive folder | live downloads |
| `~/Library/Application Support/OneDrive/settings/<account>/uploads.txt` | large uploads in progress |
| `~/Library/Logs/OneDrive/<account>/SyncDiagnostics.log` | OneDrive's hourly report (pause, sync issues, file counts) |
| `~/Library/Application Support/OneDrive/settings/<account>/UXDatabase.db` | recent activity |
| `<account>/*.ini` in the same folder | which accounts exist and their folders and web addresses |
| Which files OneDrive's processes have open | which OneDrive process serves which account, and whether it's running |

To see what Velum sees without opening it:

```sh
.build/release/Velum --dump                 # as it runs now
.build/release/Velum --dump --no-icon-text  # as if Accessibility were off
```

## Limits

- **It depends on OneDrive's undocumented internals.** OneDrive updates can change these files, so Velum
  may show less until it's updated. If something looks wrong, open an issue with the `--dump` output
  (it lists file names from your accounts, so redact what you need to).
- **Status badges understand English.** With Accessibility on, OneDrive's status text is shown in any
  language, but the icon badge reads it in English. Other languages fall back to a plain cloud.
- **OneDrive's own panel** (Pause syncing, Settings) can't be opened while its icons are hidden. Use
  Velum's ••• → Show OneDrive's Own Icons… to switch them back on when you need it.
- **Personal accounts have no recycle bin link**, because OneDrive offers no stable address for it.
  Storage totals aren't stored locally, so Manage Storage opens OneDrive's web page.

## Uninstall

1. Click Velum's cloud → ••• → Quit Velum, then delete `~/Applications/Velum.app`.
2. Remove Velum from System Settings → General → Login Items and from Privacy & Security →
   Accessibility.
3. Optionally delete `~/Library/Application Support/Velum/` (the local signing keychain) and run
   `defaults delete io.github.nafatyuk.velum`.
4. Turn OneDrive back on in System Settings → Menu Bar → Allow in the Menu Bar.

## Credits

The menu bar shell (a status item opened through macOS 27's `NSStatusItemExpandedInterfaceDelegate`
and a non-activating panel on `NSGlassEffectView`) is adapted from
[Crisp](https://github.com/didriksg/Crisp) by Didrik Galteland, under the MIT License. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](LICENSE).

---

Velum is an independent project. It is not affiliated with, endorsed or sponsored by Microsoft.
Microsoft and OneDrive are trademarks of the Microsoft group of companies.
