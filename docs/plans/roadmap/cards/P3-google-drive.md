# P3 · Google Drive, deep

**Bucket** P Providers · **Part two** (pulled forward November 12 at the owner's request; he uses Google Drive, so he is its maintainer) · **Status: done** for streaming mode, with storage, pause and the optional Google sign-in, November 12, 2026 (merged at `c8b5262`, installed) · **Waits for** C2 (C3 not needed) · **Runs alongside** P2 · **Feeds** nothing

## Brief

Google Drive for desktop has two modes:
- **Streaming,** which uses File Provider under `~/Library/CloudStorage`, so C3's generic tier covers it at basic fidelity.
- **Mirroring,** which keeps files in an ordinary folder with **no per-file sync flags** [S]. Velum can't see mirroring at all without Google Drive's own state.

The app probably draws one icon for up to four accounts [U]. The consultant rates this medium to large effort, and community-driven ([memo](../strategy-memo.md) §2, "Next", item 4; §6, risk 3).

Read the [campaign rules](../README.md#rules-every-card-follows), [G2's guide](G2-adapter-guide.md) and C3's hand-off.

**The idea:** the same as P2, with a harder house. Half of it (mirroring) has no windows to look through, so the person who lives there must show you the meters.

## Work

- **With the maintainer, first:** confirm the signals on their Mac. Candidates, all unverified [U]:
  - Google Drive's local state databases;
  - its accounts;
  - whether mirror mode exposes progress anywhere;
  - its icon's Accessibility text.
- **`Providers/GoogleDrive/`:**
  - streaming builds on the generic tier;
  - mirroring is covered only through confirmed signals, and stays `.unknown` without them, never "Up to date".
- **G2's live checklist** in both modes, on the maintainer's Mac.

## Done when

- The maintainer's checklist passes in both modes.
- Tests use synthetic fixtures.
- The maintainer is named in the README.

## Ownership and limits

You own `Providers/GoogleDrive/`. Without a maintainer, this card doesn't start.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Who maintains Google Drive | Decided November 12: the owner, who uses it; built for streaming mode |
| Show Google storage in the row | Done November 12: read from Drive's own cache by default; the optional Google sign-in (the owner's choice: "local figures + optional API too") fills in only when the cache has none |

## Hand-off

Built and live-checked overnight, November 12, 2026. The owner asked for it at bedtime ("make this app work for Google Drive too"), along with "dynamic and plug-in-and-out-able for all aspects" and "shit that works over my ideals". Codex and the Fable consultant were asked about visuals and the thorny calls.

### What was verified on this Mac (Drive for desktop 133, streaming, one account)

- **Folder.** `~/Library/CloudStorage/GoogleDrive-<email>/` holds `My Drive`, `.Trash`, `.Encrypted` and `.shortcut-targets-by-id`; Shared drives and Other computers appear there when they exist. The root reads as a live File Provider domain. Leftover folders from removed accounts, like OneDrive's dated ones, answer with no value.
- **Per-file flags work exactly like OneDrive's.** 1,076 files read as uploaded and streamed. A probe went waiting → uploading in 0.4 s → uploaded at 13.6 s; its edit uploaded 10.6 s later. There are no transient false errors (unlike iCloud's 4355).
- **FSEvents and progress.** FSEvents fire inside the folder. File Provider progress arrives per file with no kind.
- **The app and its data.**
  - One app, `com.google.drivefs`, serves every account; Google's limit is 4 accounts (`multi_account_max_accounts=4` in its process arguments).
  - Quitting it leaves the folder live, so the account stays and shows "Not running · Start". It has its own auto-restart.
  - Its local data is in `~/Library/Application Support/Google/DriveFS/<numeric-id>/`. A `my-drive` symlink there maps the data folder to the account's email.
- **Drive's own queue.** The `metadata_sqlite_db` `operations` table held 2 → 1 → 0 rows while a probe uploaded and was deleted, then emptied: it is Drive's queue of pending work.
- **What Drive doesn't expose.**
  - `activity_items` stayed empty.
  - `item_properties` has no pending or dirty keys for streamed files. Its index names `dirty-handle` and `do-not-upload`, but they never appeared.
  - `mirror_sqlite.db` has `pending_uploads` and `queued_uploads`, for mirror mode only.
  - No pause flag was found in its files. A `pause_syncing_option` process argument exists, and pausing shows up anyway as waiting files or queue rows.
  - Storage quota isn't stored locally.

### What was built (`Providers/GoogleDrive/GoogleDriveProvider.swift`)

- **Discovery** runs every 60 s, and at once whenever `~/Library/CloudStorage` changes:
  - every `GoogleDrive-<email>` folder that macOS calls a live File Provider domain, so any number of accounts appear and disappear on their own;
  - a folder macOS can't be asked about is kept only if Velum already knew it, so a hiccup can't make an account vanish and leftovers can't become ghosts.
- **Account details:**
  - Key `googledrive:<email>`; name = the full email.
  - Open in Finder goes to My Drive. View Online, Trash and Manage Storage use `drive.google.com/...?authuser=<email>`.
  - `keepsOwnHistory` false, so Recent shows uploads Velum saw finish.
- **Evidence** (Fable's rule, Codex's safeguards):
  - The live per-file flags come first, as for every service.
  - When nothing is pending, Drive's `operations` queue decides. Empty means "Up to date", with the source "Nothing pending · Google Drive's queue empty". Rows mean "Syncing changes", the lid line says "Wait before closing the lid · <account> is still syncing changes", and a queue busy for over 10 minutes raises "changes are stuck".
  - If a future Drive makes the queue unreadable, the flags still stand, and the source honestly says only "Nothing pending · Google Drive running".
  - With the app quit: "Not running", Start at the heading, and the usual "Google Drive stopped" alert.
- **Places in Recent:**
  - "In My Drive/Classes" and "In Shared drives/Lab";
  - files under `.shortcut-targets-by-id` say "In a folder shared with you";
  - `.Trash` is never tracked. A deleted file moving there was counted as an upload until this fix, and the stored list now drops such entries when it loads.

### Decisions tonight, and the options weighed

1. **The Google Drive API: not used** (Fable decided, Codex agreed).
   - Checking files against Drive's servers needs a Restricted scope (`drive.readonly` or `drive.metadata.readonly`), which means Google verification. In Testing mode the login expires every 7 days.
   - Storage quota might work under the non-sensitive `drive.file` scope (unconfirmed). That would be one notes line which "Manage Storage" already reaches in a click.
   - The API costs networking, a Keychain token, a consent per account, and Velum's "no network connections" promise. The owner's authorization was "if you end up needing" it, and the local signals made it unneeded.
   - So no Google Cloud project was created and nothing was changed in Cloud Console. If he wants storage in the row, the plan is option (b): `drive.file` only, opt-in, set up with him awake.
2. **Row name: the full email**, both consultants agreed. It is the only local, unique identity, and what Google shows. Long ones truncate in the middle; the full address shows on hover and to VoiceOver. Shared drives stay inside their account.
3. **Ten accounts: compact rows, not collapsing.**
   - Fable proposed shrinking healthy rows to one line once there are more than six accounts; Codex proposed collapsible headings with a summary.
   - Compact rows won: nothing gets hidden and there's no state to remember.
   - Both proposed a count on each heading, which was built ("4 accounts", "2 of 3 up to date").
4. **The "any CloudStorage folder" tier (C3): not tonight**, both agreed. No other client is installed here, and a false "synced" for an untested client is risk 4.

### Plug-and-play, the owner's rule ("whatever is left still works")

- **A service with no live account shows nothing.** OneDrive installed but signed out of everything, or uninstalled with its settings left behind, no longer counts as "stopped". The fallbacks that assumed OneDrive (lid line, icon, banner, menu) were made neutral.
- **The panel's shape is fixed:** always "Cloud Sync", always a heading per service, in a fixed order. Services coming and going never rearrange it, and a sole stopped service still has Start at its heading (Fable's catch).
- **Height:** the panel caps at the screen's height, with the header and lid line pinned and the rest scrolling.
- **With many accounts:** the summary says "N of M accounts need attention", and the tooltip and VoiceOver list only the troubled accounts plus "N accounts up to date".
- **An account that disappears** with uploads still pending says so once ("<account> was disconnected · 3 files hadn't reached the cloud when it went away"), then goes quiet. A removed service never gets a false "running again" note.
- **The icon** takes the worst state of every account and stopped app, so a stopped OneDrive no longer hides a failing upload elsewhere (Codex's catch).
- **Nothing specific to this Mac in the code:** no email, account ID or path. Service-specific knowledge (bundle IDs, folder names, Drive's database) is there on purpose, so Velum works on any Mac with these apps.

### Tests and checks

- 47 tests (`Scripts/test.sh`), including Google Drive's config and queue, the data-folder mapping, plain folders not becoming accounts, the busy lid line, the stuck-queue alert, the disconnect notice, the icon's worst state, and many-account summaries.
- **Test script:** with only the Command Line Tools, swift-build sometimes loses Swift Testing's macro plugin. `Scripts/test.sh` names the active toolchain's plugin folder, which made three runs in a row stable.
- **Live checks** with the installed app and test files (approved by the owner, all deleted):
  - iCloud and Google Drive uploads appeared in Velum's recorded uploads;
  - quitting Google Drive kept its account;
  - a deleted file is no longer recorded as an upload.

### Left for later

- **Mirror mode** isn't covered. Its files sit outside File Provider; `mirror_sqlite.db` has `pending_uploads` and `queued_uploads` to start from. Today a mirrored My Drive simply isn't watched.
- **More than one Google account** is tested only with fixtures; this Mac has one.
- **Storage in the row**, through the Drive API with the owner awake (option b above).
- **Codex's longer list:**
  - give account identities a generation, so a reused OneDrive slot can't inherit another account's history;
  - move vendor filename filters (`.fetch`) into the adapters;
  - reconcile FSEvents gaps instead of letting them expire after 15 minutes.

### Added November 12, morning (owner's requests)

The owner asked for three cheap fixes and for Google storage, the latter "as a distinctly optional thing".

- **Pause.** Pausing Google Drive creates an empty `DriveFS/user-paused` file at the top of DriveFS, so it covers every account. This was found by diffing Drive's settings and databases before and after the owner paused it. The same diff found no change in the process arguments, the prefs or the databases.
  - Velum now shows "Paused", or "Paused, N waiting".
  - Start, Restart and Quit in the ••• menu now exist for every service with an app (`ProviderID.clientBundleID`).
  - Quitting from Velum suppresses the "stopped" alert for that service (`Notifier.userStopped[provider]`).
- **Storage, no sign-in.** The same diff showed that Drive caches the account record, including its quota, in `metadata_sqlite_db` → `properties` → `driveway_account`. It is a protobuf; message 2 → 3 → 1 holds:
  - 1 = limit;
  - 3 = used by all services;
  - 8 = remaining;
  - 9 = used by the user.

  On this Mac it read 400 GiB, 185.97 GiB used and 214.03 GiB remaining, and limit − used = remaining to the byte. Velum shows the figures only when that arithmetic holds, so a changed shape shows nothing rather than a wrong number. Codex and Fable were asked about the display; Fable decided:
  - "214 GB free of 400 GB" in binary units, as Google labels them; the hover text says it's shared by Drive, Gmail and Photos, and how much your files use.
  - "Almost full" (orange) past 90% used and under 10 GB free.
  - "Storage full" under 100 MB free: an orange note, "Storage full" or "N accounts full" at the heading, and one alert per crossing.
  - Storage never changes a row's state, the lid line or the icon.
- **The optional Google sign-in for storage** is being built in a separate session, on its own branch (`google-storage`), as a fallback for accounts whose cache has no figures. It plugs into `GoogleDriveProvider.signInStorage`. Its wording, decided by Fable:
  - "Show Storage…", then "Stop Showing Storage", and "Sign In Again…" after expiry;
  - an alert before opening the browser;
  - hidden in builds without the client configuration.
- **iCloud "Recently Deleted".** A deep link doesn't exist: `icloud.com/iclouddrive/recently-deleted` opens "Item Unavailable". The row gets "Recover Deleted Files…", which opens Apple's documented `icloud.com/recovery`. Each service now names this item itself (`ProviderID.deletedFilesLabel`).

### Hand-off: the optional Google sign-in for storage (November 12, afternoon)

Built in a parallel session on branch `claude/google-storage-318c3f`, as the fallback the morning's work
left a seam for. The owner's words: "a distinctly OPTIONAL thing: people can use it and it enhances what
Velum can do and show, but for core functions it isn't needed. But it is very much there."

**What it does.**
- Per Google account, off by default, in Fable's wording (sent by the main session). ••• → **Show
  Storage…** shows the consult's alert ("Show storage for <email>?" … "Continue in Browser"), then opens
  Google's consent page in the default browser. After that, the row's storage comes from the Drive API whenever Google Drive's own cache has no
  figures, with the main session's note format ("… from your Google sign-in, 3 min ago").
- **The cache always wins.** The provider asks `signInStorage` and `signInNote` only when the cache is
  empty (now through one helper, `GoogleDriveProvider.storage(cached:email:)`, so it's tested), and only
  that question starts a fetch, so a cache with figures means no request at all. The same question tells
  the menu whether "Show Storage…" would show anything: it appears only while the cache is empty, and once
  the sign-in is on, "Stop Showing Storage" is always offered.
- **Stop Showing Storage** revokes the grant at Google (`oauth2.googleapis.com/revoke`), deletes the
  Keychain item and clears the switch. After `invalid_grant` the row says "Storage not shown · sign in again
  from the ••• menu", and the menu offers **Sign In Again…** beside it.
- While the browser is open: the note "Waiting for Google sign-in…" and **Cancel Sign-In**; it reverts
  silently after 5 minutes.
- **A sign-in as another account is revoked and discarded,** with the alert "That was <other>. Sign in as
  <email> to show its storage." If Google ever reports a different email later, the row says "Storage not
  shown · the Google sign-in is for <other>" and shows no figures.
- With the switch off: no network connections and no Keychain reads (tested).

**How.** `Providers/GoogleDrive/GoogleSignIn.swift` (OAuth) and `GoogleSignInStorage.swift` (per-account
state, Keychain, menu items, debug commands).
- Google's installed-app flow: loopback redirect to `127.0.0.1:<port macOS picks>` (BSD socket, loopback
  only, closes as soon as the code arrives; the `state` must match), PKCE S256, `access_type=offline`,
  `prompt=consent`, `login_hint=<email>`.
- Scope `drive.file` only. The Cloud Console lists it as non-sensitive.
- Token exchange and refresh at `oauth2.googleapis.com/token`, with the client secret (Google requires it
  even with PKCE). The refresh token is a generic password, "Velum Google Sign-In", keyed by email, in the
  login Keychain; the access token lives only in memory.
- `drive/v3/about?fields=user(emailAddress),storageQuota`, about every 30 minutes, and on the next refresh
  after the panel opens when the figures are over 5 minutes old. A 401 refreshes the token once and retries;
  a network failure keeps the last figures.
- `user.emailAddress` must match the row's email (case-insensitive), or the row says so and shows no
  figures.
- The switch: UserDefaults `googleSignInAccounts` (lowercased emails).

**Verified live with the owner (November 12).**
- **`about.get` does return `storageQuota` under `drive.file`.** This was the open question; the scope
  didn't need widening.
- The owner signed in through `build/Velum.app/Contents/MacOS/Velum --google-sign-in <email>` and clicked
  Allow himself.
- Google answered with his address and limit 429,496,729,600 bytes (400 GiB), used 199,682,857,672
  (185.97 GiB), Drive 568,993,831. That matches Drive's local cache to the byte.
- `--google-storage <email>` then fetched again through the Keychain's refresh token, with no Keychain
  prompt (same signing identity).
- Tests: 28 for the sign-in, covering:
  - token handling with a stubbed network: exchange fields, refresh, `invalid_grant`, a 401 retried once;
  - quota parsing with and without a limit;
  - the email mismatch, at sign-in (discarded and revoked) and later;
  - "off makes no request", and no Keychain read;
  - "the cache wins", and the menu's rules;
  - the whole sign-in through the real loopback port, with the test playing the browser.

  `Scripts/test.sh`: 82 tests pass.
- His switch is on and his token is in the Keychain, but his cache has figures, so the sign-in stays idle.

**Google Cloud setup (owner's Gmail, Claude in Chrome, with the owner awake).**
- Project "Velum" (`velum-514523`), Drive API enabled.
- Google Auth Platform: External, scope `drive.file`, Desktop client "Velum for macOS". The owner OK'd
  accepting the Google API Services User Data Policy.
- **In production.** Google won't publish without a public home page and privacy policy, which is how
  Valise solved it too. With the owner's OK, `nafatyuk/velum` went **public** after a history scrub (every
  file in all 8 commits plus messages, against this Mac's Gmail, Apple ID, OneDrive account and org names,
  Drive's account ID and the account and file names in `--dump`: nothing but the author's name and GitHub
  handle). The pages live on an orphan `gh-pages` branch, served at <https://nafatyuk.github.io/velum/> and
  `/privacy.html`; authorized domain `nafatyuk.github.io`. Google's confirmation asked for no verification
  (no logo, one domain, no sensitive scopes), so sign-ins don't expire after 7 days.
- The client ID and secret are in `Resources/GoogleOAuthClient.plist` (git-ignored; `build.sh` copies it
  only if it exists; without it the menu items are hidden). A backup is at
  `~/Library/Application Support/Velum/GoogleOAuthClient.plist`; Google won't show the secret again.

**Left for later.**
- **Merging: done.** Merged into `main` as a fast-forward at `c8b5262` (owner's go-ahead), the client plist copied into `Resources/`, installed and pushed. The installed Velum held no network connections afterwards: the owner's switch is on, but his cache has figures.
- **Whenever Velum is rebuilt** from a fresh clone, copy
  `~/Library/Application Support/Velum/GoogleOAuthClient.plist` into `Resources/` before
  `./build.sh --install`; without it the build hides the sign-in items.
- `--google-storage <email>` and `--google-sign-out <email>` remain for testing.
