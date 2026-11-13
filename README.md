# Velum

**Every OneDrive account, one cloud in your menu bar.**

OneDrive for Mac draws a separate menu bar icon for every account you sign in to, so a personal account
plus a work or school account means two clouds, three accounts means three. Hiding them (in System
Settings or with a menu bar manager) also hides whether your files are synced.

Velum merges them instead of hiding them: one native menu bar icon and one Liquid Glass panel that show
every account's sync status, recent activity across all of them, and quick ways into each account.
iCloud Drive, which has no menu bar icon at all, and every Google Drive account join them in the same
panel. Services and accounts come and go on their own: sign one out or uninstall an app, and the rest
keeps working.

*A velum is a thin veil of cloud that stretches across several separate clouds and joins them.*

## What you get

- **One icon.** A cloud that gets a small badge when any account is syncing, paused, has a sync issue,
  or isn't running.
- **"Safe to close the lid?"** The top of the panel answers it: every change on this Mac is in the cloud,
  or N files are still on the way up, or some can't upload, or Velum can't vouch for it.
- **Alerts when something's wrong.** Uploads failing, a sync issue, uploads stuck for 10 minutes, or
  OneDrive stopping on its own. See [Alerts](#alerts).
- **Stuck files, by name.** Files whose latest change still isn't in the cloud after 10 minutes, or that
  can't upload, are listed under "Not in the cloud yet" with how long they've waited or why they fail.
  Click one to show it in Finder. The stuck alert names the oldest one.
- **iCloud Drive too.** Its own row under an iCloud heading, with the same live upload tracking, the
  lid line and alerts covering it, Desktop & Documents included when you sync them, and free iCloud
  storage. iCloud keeps no history Velum can read, so Recent shows the iCloud uploads Velum saw finish.
- **Google Drive too.** One row per signed-in Google account (shown by email), with the same live upload
  tracking. "Up to date" also needs Google Drive's own queue of pending work to be empty, a paused Google
  Drive says "Paused", and each account shows its free Google storage ("214 GB free of 400 GB"), read
  from Google Drive's own copy on your Mac, with no sign-in.
- **Every account at a glance.** Live status for each account: files uploading, waiting to upload or
  failing (with the reason), downloads in progress, and when it last did something. Each status says
  where it came from, and Velum never says "Up to date" without evidence.
- **Recent activity, merged.** Uploads, downloads, deletes and moves from all accounts in one list.
  Click a file to show it in Finder.
- **Quick actions.** Open an account's folder or its web view, its recycle bin or trash (iCloud: Recover
  Deleted Files), storage page; start, restart or quit OneDrive and Google Drive; open at login.

Velum needs no special permissions and never modifies any sync app's files or settings. It makes no
network connections, unless you turn on [Show Storage](#optional-google-sign-in-for-storage) for a Google
account; then only Google's sign-in and the Drive API. The only things it does to OneDrive are the Restart and Quit OneDrive commands you click, and Start for a
sync app that isn't running; everything else it only reads.

## Requirements

- macOS 26 or later (built and tested on macOS 27).
- OneDrive for Mac, signed in to one or more accounts (tested with OneDrive 26.204 and 26.212).
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
that signature stays the same across builds, macOS keeps Velum's Accessibility permission (if you
allow it) when you rebuild.

## First run

1. **Hide OneDrive's own icons.** System Settings → Menu Bar → Allow in the Menu Bar → turn **OneDrive**
   off. OneDrive keeps syncing; only its icons go away.
2. **Find Velum's icon.** macOS 27 puts new menu bar icons in its hidden section (behind the « control).
   ⌘-drag Velum's cloud to where you want it.
Velum works fully from here, with no permissions. One optional extra: if you keep OneDrive's own icons
allowed (for example tucked into the hidden section instead of switched off), Velum can also show
OneDrive's exact wording ("Uploading file (58%)", "Paused"). Turn it on from Velum's ••• menu → Show
OneDrive's Exact Status…, which asks for Accessibility access.

## How Velum knows

Each account's status line names its source:

- **Live from macOS.** Velum watches your OneDrive folders for changed files (FSEvents) and asks macOS's
  File Provider where each one is: waiting, uploading, uploaded, or failed. OneDrive keeps those flags
  accurate to within a second or two. Downloads come from the transfer progress File Provider publishes
  for each folder. Changes made while Velum was quit are caught up when it starts (up to a day back).
- **Nothing pending · OneDrive report 12 min ago.** "Up to date" means nothing is moving or waiting right
  now and OneDrive's own hourly report (`SyncDiagnostics.log`) says it's healthy. Once a report is over
  75 minutes old it's old: the row turns grey and says "Can't tell · last report is old", never green.
- **OneDrive report 2 hr ago.** Account-wide states such as Paused or Sync issue come only from that hourly
  report, so they can be up to an hour old. An old one reads "Last reported: Paused · old" and raises no alert.
- **Google storage** comes from Google Drive's own record of your account on this Mac. Velum shows it
  only when its figures add up (limit − used = remaining), and storage never changes an account's status
  or the lid line; a full account gets one alert and "Storage full" at its heading.
- **Nothing pending · Google Drive's queue, live.** For Google Drive, "Up to date" means nothing is moving
  or waiting right now and Google Drive's own list of pending work is empty. If Velum can't read that list,
  the row says it can't tell.
- **Nothing pending · iCloud status 4 min ago.** For iCloud Drive, "Up to date" means nothing is moving
  or waiting right now and macOS's `brctl status`, checked every 10 minutes, calls iCloud Drive caught up.
  It's old after 25 minutes.
- **From OneDrive, live.** OneDrive's own icon text, when you've turned that option on and its icons exist.

When Velum has no evidence it says "Can't tell" ("Can't tell yet" while it waits for a first answer), with a
grey question mark, a line saying why and what would end it, and the menu bar's plain cloud. The ⓘ in the
panel's header, or ••• → What the Status Means…, explains every icon, light and source.

Everything is read-only. Velum doesn't read file contents, other apps' windows, your screen or your
keystrokes.

| Source | Used for |
|---|---|
| FSEvents for each OneDrive folder, plus File Provider's per-file sync flags | live uploads, waiting files, upload errors |
| File Provider transfer progress for each OneDrive folder | live downloads |
| `~/Library/Logs/OneDrive/<account>/SyncDiagnostics.log` | OneDrive's hourly report (pause, sync issues) |
| `~/Library/Application Support/OneDrive/settings/<account>/UXDatabase.db` | recent activity |
| `<account>/*.ini` in the same folder | which accounts exist and their folders and web addresses |
| Which files OneDrive's processes have open | which OneDrive process serves which account, and whether it's running |
| OneDrive's menu bar item titles (Accessibility, optional) | OneDrive's exact wording, while its icons exist |
| FSEvents and per-file sync flags for iCloud Drive (and `~/Desktop`, `~/Documents` when they're in iCloud) | iCloud's live uploads, waiting files, upload errors |
| `/usr/bin/brctl status` and `brctl quota` | iCloud Drive's account-wide state and free storage |
| FSEvents and per-file sync flags for each `~/Library/CloudStorage/GoogleDrive-<email>` folder | Google Drive's live uploads, waiting files, upload errors |
| The `operations` table in `~/Library/Application Support/Google/DriveFS/<account>/metadata_sqlite_db` | whether Google Drive still has work queued |
| The `driveway_account` record in the same database | the account's Google storage |
| `~/Library/Application Support/Google/DriveFS/user-paused` | whether Google Drive is paused |

To see what Velum sees without opening it:

```sh
.build/release/Velum --dump                 # as it runs now
.build/release/Velum --dump --no-icon-text  # as if Accessibility were off
```

## Optional: Google sign-in for storage

Velum shows a Google account's storage from Google Drive for desktop's own local cache, with no sign-in.
If that cache ever has no figures for an account (a future Google Drive that stops keeping them), you can
let Velum ask Google instead: the Google account row's ••• menu → **Show Storage…** (or, while Google
Drive's own figures already show, **Sign In to Google for Storage…**), which says what will happen and then
opens Google's sign-in in your browser. Signed in, Velum still prefers Google Drive's figures and asks
Google only when they're missing. Once it's on, **Stop Showing Storage** is always there, and after that the
way back in is too. It's off by default, per account, and Velum works fully without it.

- **What it adds:** the account's storage (used, of how much, and how much is Drive), refreshed about
  every 30 minutes and when you open the panel. Velum uses these figures only when Google Drive's cache
  has none.
- **What it asks Google for:** the `drive.file` permission only. It covers files an app creates or you
  open with it; Velum creates none, so it can't see any of your files. Google's consent page says so. Under
  it, Drive's `about` call still answers with the account's email and storage quota, which is all Velum
  reads. If you sign in as a different Google account, Velum discards that sign-in and says so.
- **Velum's one network connection,** only while it's on: your browser opens Google's consent page, Google
  redirects back to a temporary port on `127.0.0.1`, and Velum talks to `oauth2.googleapis.com` (tokens)
  and `www.googleapis.com` (storage). With it off, Velum makes no connections and reads nothing from the
  Keychain.
- **What it keeps:** the refresh token, in your login Keychain as "Velum Google Sign-In" (one item per
  account email), and the on/off switch in Velum's preferences.
- **Turning it off** (••• → Stop Showing Storage) revokes the grant at Google, deletes the Keychain item
  and clears the switch. If the sign-in expires or you remove Velum's access in your Google Account, the row quietly says "Storage not
  shown · sign in again from the ••• menu" (••• → Sign In Again…); Velum never pops anything up on its own.
- **Privacy policy:** <https://nafatyuk.github.io/velum/privacy.html> (served from this repo's `gh-pages`
  branch, which Google's consent screen links to).

### Building it yourself: your own Google OAuth client

A Velum built from source doesn't offer the sign-in until it has an OAuth client, which stays out of git
(like rclone, each builder makes their own; it's free):

1. In [Google Cloud Console](https://console.cloud.google.com/projectcreate), create a project (any name).
2. **APIs & Services → Library → Google Drive API → Enable.**
3. **Google Auth Platform → Get started:** app name (e.g. "Velum"), your email as support and contact
   email, audience **External**, then agree to Google's API Services User Data Policy.
4. **Data Access → Add or remove scopes:** add `https://www.googleapis.com/auth/drive.file`, then Save.
5. **Branding:** Google won't publish the app without a public home page and privacy policy. Add their
   links and their domain under Authorized domains (a GitHub Pages site works, as Velum's does). Then
   **Audience → Publish app → Confirm**, so the sign-in doesn't expire. With only `drive.file` (a
   non-sensitive scope), no logo and few domains, Google asks for no verification. If you'd rather stay
   in Testing, skip the pages and add yourself as a test user; Google then ends the sign-in every 7 days.
6. **Clients → Create client:** application type **Desktop app**, any name. Copy its client ID and secret.
7. Put them in `Resources/GoogleOAuthClient.plist` (ignored by git), then build:

   ```sh
   plutil -create xml1 Resources/GoogleOAuthClient.plist
   plutil -insert ClientID -string 'YOUR-ID.apps.googleusercontent.com' Resources/GoogleOAuthClient.plist
   plutil -insert ClientSecret -string 'YOUR-SECRET' Resources/GoogleOAuthClient.plist
   ./build.sh --install
   ```

Google treats a desktop app's client secret as not really secret (anyone can read it from the app), which
is why the flow also uses PKCE. To test without replacing your installed Velum:

```sh
build/Velum.app/Contents/MacOS/Velum --google-sign-in you@gmail.com   # sign in, print the storage
build/Velum.app/Contents/MacOS/Velum --google-storage you@gmail.com   # fetch again with the saved sign-in
build/Velum.app/Contents/MacOS/Velum --google-sign-out you@gmail.com  # revoke and forget
```

## Alerts

Velum alerts you when:

- files can't upload (with the reason),
- OneDrive reports a sync issue,
- uploads have waited more than 10 minutes,
- OneDrive stops without you quitting it from Velum.

A problem has to last 30 seconds before Velum mentions it, it's mentioned once, and you get one
"resolved" note when it clears. Click an alert to open Velum's panel. Turn alerts off with ••• → Notify
About Problems.

macOS only lets apps signed with an Apple-issued certificate (Developer ID or Apple Development) use
system notifications; it refuses locally signed builds without asking. Built from source, Velum
therefore shows its own alert as a small glass banner under its menu bar icon. A build signed with
an Apple-issued certificate uses system notifications automatically.

## Troubleshooting: the debug log

When something looks wrong, turn on ••• → **Debug Logging**. Velum then writes what changes and what goes
wrong to `~/Library/Logs/Velum/Velum.log`:
- every account's status changes, services and accounts coming and going, and the lid line;
- alerts, missed-change gaps, background checks that failed;
- Google sign-in events and the actions you click in Velum.

••• → **Open Debug Log** opens it in Console. It stays on your Mac, holds no file contents or sign-in
tokens, and rotates at 2 MB. Status lines can name a file that's failing to upload, as the panel does. It's
off by default.

## Limits

- **It depends on OneDrive's undocumented internals.** OneDrive updates can change these files, so Velum
  may show less until it's updated. If something looks wrong, open an issue with the `--dump` output
  (it lists file names from your accounts, so redact what you need to).
- **Paused and other account-wide states can lag up to an hour**, because only OneDrive's hourly report
  carries them (unless OneDrive's own icon text is available).
- **Renaming a folder while files inside it are still uploading** can make Velum lose sight of those
  files until they change again.
- **OneDrive's exact wording is read in English.** In other languages it's shown as written, but the
  icon badge treats it as unknown.
- **OneDrive's own panel** (Pause syncing, Settings) can't be opened while its icons are hidden. Use
  Velum's ••• → Show OneDrive's Own Icons… to switch them back on when you need it.
- **Google Drive's mirror mode isn't covered.** Velum watches Google Drive's streamed folders (the
  default). A My Drive set to "Mirror files" lives outside them. Storage comes from what Google Drive keeps
  on your Mac; the Google Drive API is used only if you turn on the optional sign-in.
- **iCloud's and Google Drive's Recent lists are partial.** They show only uploads Velum saw finish
  while it was running, not downloads or changes from your other devices.
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
[Crisp](https://github.com/didriksg/Crisp) by Didrik Galteland, under the MIT License, and Velum's alert
banner follows the idea of Crisp's on-screen banner. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](LICENSE).

---

Velum is an independent project. It is not affiliated with, endorsed or sponsored by Microsoft.
Microsoft and OneDrive are trademarks of the Microsoft group of companies. Apple, iCloud and iCloud Drive
are trademarks of Apple Inc. Google Drive is a trademark of Google LLC.
