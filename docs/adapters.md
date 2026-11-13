# Writing an adapter for a sync service

Velum puts every cloud account on a Mac behind one menu bar icon and one panel. Each sync service reaches
it through an **adapter**: a small piece of Swift that finds the service's accounts and reads what only
that service knows. Adapters are how Velum grows, and the best way to contribute is to write one for a
service you use every day.

This guide is a recipe for someone who won't have the author at their elbow. It covers what an adapter
answers, the rules that keep Velum honest, the three adapters that exist (OneDrive, iCloud Drive and
Google Drive) as worked examples, how to test without anyone's data, the live checklist, and why every
adapter needs a named maintainer.

**One rule above the rest:** Velum never says "Up to date", "safe" or green without evidence it can name.
When the evidence runs out, the answer is "Can’t tell", with a reason. A false "synced" is the worst bug
this app can have, because it is the one that loses someone's work.

When this guide and the code disagree, the code wins. Please open an issue so the guide can be fixed.

Contents:
- [How an adapter fits in](#how-an-adapter-fits-in)
- [What an adapter answers](#what-an-adapter-answers)
- [How Velum merges your evidence](#how-velum-merges-your-evidence)
- [The trust rules](#the-trust-rules), rules 1 to 10
- [The three worked examples](#the-three-worked-examples)
- [Adding a service, file by file](#adding-a-service-file-by-file)
- [Testing without anyone's data](#testing-without-anyones-data)
- [The live checklist](#the-live-checklist)
- [Maintainers](#maintainers)
- [The pull-request checklist](#the-pull-request-checklist)

## How an adapter fits in

```text
   ~/Library/CloudStorage/…, iCloud Drive, ~/Desktop …        the service's own files, app and tools
                     │                                                        │
   shared live evidence, the same for every service:              your adapter (SyncProvider)
   FSEvents + per-file upload flags (UploadTracker)               accounts, folders, client running,
   transfer progress (TransferMonitor)                            account-wide report, pause, history,
                     │                                            storage, compatibility checks
                     └──────────────► Collector.status ◄──────────────────────┘
                                 one merge, one fixed order
                                          │
              rows, icon, "Safe to close the lid?", alerts, stuck files, legend, Velum --dump
```

Sync clients built on Apple's File Provider expose the most important evidence the same way, and Velum
reads it without code of your own, once step 1 of the [live checklist](#the-live-checklist) confirms it for
your client. When your adapter lists an account's folders in `AccountConfig.watchRoots`, Velum watches them
with FSEvents and asks macOS where each changed file is: waiting, uploading, uploaded or failing, with
macOS's reason. It also reads the transfer progress File Provider publishes for each folder. You don't call
any of that; Velum starts watching on the next refresh. The tracker has limits (it skips some scratch
files, checks a few hundred files per pass, and says so when it may have missed changes), and they apply to
every service alike.

**Confirm the flags before an adapter ships.** The lid line trusts the per-file flags of every watched
folder. They were real for OneDrive, iCloud Drive and Google Drive, but that was checked on a real Mac each
time, and a client could set them differently. Don't merge an adapter that lists a folder in `watchRoots`
until step 1 of the live checklist has confirmed its flags on a real Mac.

Your adapter adds what only the service knows:
- which accounts exist, and where their folders are;
- whether the service's app is running;
- an account-wide status, such as a report the client writes, a queue it keeps, or a pause marker;
- extras: history, storage, the client's own status text.

The `Collector` (in `Sources/Velum/Model.swift`) calls every adapter's `gather` on one serial queue at every
refresh. Refreshes happen every 2.5 seconds and whenever a watched file changes. They pass `force: true`
when `~/Library/CloudStorage` changes or a service's app launches or quits.

## What an adapter answers

The protocol lives in `Sources/Velum/Providers/SyncProvider.swift`. It is deliberately small:

```swift
protocol SyncProvider: AnyObject {
    var id: ProviderID { get }
    /// Called on the collector's serial queue for every refresh. Must not block for long.
    func gather(force: Bool, now: Date) -> ProviderEvidence
}
```

`gather` returns a `ProviderEvidence`, with one `AccountEvidence` per account. Each field below says what
it means, and what to return when you can't tell.

### `ProviderID`: the service itself

| Member | Means | When you can't tell |
|---|---|---|
| the case and its raw value (`"googledrive"`) | The service. The raw value keys saved state and alerts, so it never changes once shipped | — |
| `name` | What headings and alerts call it ("Google Drive") | — |
| `clientBundleID` | The service's own app. It drives Start, Restart and Quit, the "Not running" heading, the refresh when the app launches or quits, and the version that A7's checks run against | `nil` when there is no app to start or stop, as for iCloud Drive, which is part of macOS |
| `deletedFilesLabel` | What the row's ••• menu calls the way back to deleted files ("Trash", "Recycle Bin", "Recover Deleted Files…") | It shows only when the account has a `recycleBinURL` |
| `testedVersions` (in `Providers/Compatibility.swift`) | The client versions your live checklist ran on. Never empty: an adapter ships with at least the version its maintainer checked | — |
| `versionOwner` | Whose version decides how the internals read: the app's, or macOS's for a system service | — |

### `ProviderEvidence`: the service on this Mac, now

| Field | Means | When you can't tell |
|---|---|---|
| `present` | The service has at least one live account here. A service that isn't present shows nothing: no heading, no "stopped" alert | `false`. Installed but signed out, or uninstalled with files left behind, is not present |
| `clientRunning` | The app runs. `false` puts "Not running" and Start at the heading and makes the lid line say so. It also alerts, unless the user quit the app from Velum in the last two minutes | `nil` when there is no app (iCloud Drive), or when the app can't be found. Never a guessed `false`, which raises a false "stopped" alarm, and never silently: keep `running` `true` on the accounts and have your checker record an `unavailable` check with a row note ("Can’t find the Example app · uploads are still tracked"). The shipped adapters predate this advice |
| `accounts` | One `AccountEvidence` per live account | — |
| `activity` | History the service keeps itself, as `Activity` items, using the kind codes in `Activity` (4 downloaded, 5 uploaded, 6 deleted, 10 and 11 moved, 12 restored) | Empty. Leave out items you can't map, rather than showing them as "Synced". If the service keeps no history, set `keepsOwnHistory: false` on the account |
| `trouble` | A service-wide problem for the heading ("Storage full") | `nil` |
| `compatibility` | Your A7 report (see [rule 9](#rule-9-notice-when-the-client-changes-underneath)). Set by `CompatibilityReport.record(into:logged:)`, never by hand | — |
| `axTrusted`, `liveItemsFound` | OneDrive's Accessibility path only | Leave them alone |

### `AccountEvidence`: one account, before the live evidence is merged in

| Field | Means | When you can't tell |
|---|---|---|
| `config` | The account's `AccountConfig` (below) | — |
| `name` | The row's name. An email is fine when that is the only unique local identity (Google Drive) | `config.fallbackName` |
| `running` | The app serves this account. `false` makes the row "Not running, so nothing is syncing" | `true` (the default) when the service has no app, or when you can't tell which process serves which account. OneDrive waits two minutes before saying it can't tell |
| `pid` | The process serving this account | `nil` |
| `exactStatus` | The client's own words for this account (OneDrive's icon text). Non-empty text outranks everything except "not running", live failures included, and goes through `SyncState.classify`, which knows OneDrive's English wording only | **Leave it `nil`** (see [rule 6](#rule-6-live-evidence-comes-before-reports)) |
| `report` | The account-wide status: a `ProviderReport` (below) | `nil`. Unless macOS's live evidence gives the row a status (files waiting, moving or failing), it then says "Can’t tell yet", with your `unknownReason` |
| `unknownReason` | Why there is no status, and what would end it, in a sentence: "Checking iCloud now. This takes about 15 seconds." | Always set it when `report` is `nil` |
| `lastActivity` | When the account last did something, for "last change 5 min ago" | `nil` |
| `notes` | Facts about the account for its own line: "Desktop & Documents included", "214 GB free of 400 GB" | Empty |
| `notesHelp`, `notesNeedAttention` | Hover text for the notes; orange when they need the eye (storage almost full) | `nil`, `false` |
| `storageFull` | Out of storage: one alert per time it fills up. Set `ProviderEvidence.trouble` too, for the heading. Never changes the row's state | `false` |
| `workingSince` | Since when the service's own queue has had work. It raises "changes are stuck" past the stuck threshold (10 minutes by default), and only counts beside a live report (`timed: false`) whose state is `.syncing` | `nil` |
| `compatibilityNote` | Why some evidence was dropped. Set by `CompatibilityReport.record`, never by hand | — |

### `AccountConfig`: who the account is and where it lives

Built at discovery. The panel compares it from one refresh to the next, so keep it free of anything that
changes by itself.

| Field | Means |
|---|---|
| `key` | Unique across every service and stable across launches: the upload tracker's saved state, its FSEvents resume point and alerts are keyed by it. Prefix it with your raw value and the most stable identity you have: `"googledrive:<email>"`, or the folder's name when that is all there is. OneDrive's bare `"Personal"` and `"Business1"`, and iCloud's `"iCloudDrive"`, are history, not a pattern |
| `provider` | Your `ProviderID` |
| `folder` | What Open in Finder opens |
| `watchRoots` | Every folder whose changes count. Velum watches exactly these, so a live folder of the service that no account lists is a blind spot (A7 can check for it) |
| `places` | Every path that leads into the account, symlinks included, with how to say where a file is (`NamedRoot`: "In My Drive/Classes", "In the top of OneDrive-Personal", or `flat` for folders named by IDs) |
| `fallbackName` | The account's name when nothing better is known |
| `webURL`, `recycleBinURL`, `storageURL` | View Online, the deleted-files item, Manage Storage. Only `webURL` is required |
| `keepsOwnHistory` | `false` when the service keeps no history Velum can read. Velum then records the uploads it sees finish, and the legend says Recent is partial for your service |

### `ProviderReport`: an account-wide status, with its source and age

| Field | Means |
|---|---|
| `label` | The source, as the row names it: "OneDrive report", "iCloud status", "Google Drive's queue" |
| `written` | When the status was true. For live evidence, `now` |
| `state` | `.ok`, `.paused`, `.offline`, `.error`, `.unknown`, or `.syncing` for live work in progress |
| `headline` | The row's words: "Up to date", "Paused", "Sync issue", "Can’t tell" |
| `timed` | `true` for a status written now and then (OneDrive's hourly report, Velum's 10-minute `brctl` check); `false` for live evidence that has no time of its own (Google Drive's queue) |
| `every` | For timed reports: how often a fresh one comes. Past `every` plus 15 minutes the report is old, and old is never green. **A timed report without `every` can never go old: always set it** |
| `reason` | Why this report leaves the status unknown or old, in your service's words |

## How Velum merges your evidence

`Collector.status` turns each account's evidence into a row. The order is the same for every service, and
the first rule that applies wins:

1. **Not running** (`running == false`): "Not running, so nothing is syncing".
2. **The client's own words**, when `exactStatus` is non-empty, classified by `SyncState.classify`. Words it doesn't know read as unknown.
3. **Failed uploads**, from macOS: "1 file can’t upload", with macOS's reason.
4. **Files moving**, from macOS: "Uploading 3 files", "Downloading 1 file", "Syncing 4 files".
5. **Files waiting**, from macOS: "Waiting to upload 2 files", or "Paused, 2 files waiting" when a usable report says paused.
6. **Progress with no direction**, from macOS: "Syncing changes".
7. **Your report.** It keeps its own headline. A timed report that is old, or dated more than five minutes in the future, is never green. A healthy report's source gains "Nothing pending · " when Velum's own watching has no gaps.
8. **Nothing at all:** "Can’t tell yet", with your `unknownReason`.

Then, if A7's checks dropped some of your evidence, the account's `compatibilityNote` leads the reason line.

**The lid line** ("Safe to close the lid?") is stricter. It uses only live evidence: files waiting,
uploading or failing, whether Velum's watching has gaps, whether each app runs, live queues (a report with
`timed == false` and state `.syncing` holds it at "still syncing"), and A7 checks that guard it. A periodic
report never decides the lid, fresh or old.

**The icon** shows the worst state of any account or stopped app.

## The trust rules

### Rule 1: never assume OK

`.ok` needs evidence you can name. A running process, a folder that exists or a file with no complaint in
it is not evidence that everything is uploaded. When you aren't sure, return no report and say why
(`unknownReason`), or return a report with state `.unknown` and a `reason`.

Google Drive's first version showed "Up to date", with the source "Nothing pending · Google Drive running",
when its queue couldn't be read. That was a false green, because deletes and renames would go unseen, and
it was removed. An unreadable queue now means no status, and the lid line can't vouch.

### Rule 2: every status has a source and an age

Every `ProviderReport` names its source (`label`) and says when it was true (`written`). Timed reports set
`every`, so Velum can tell when they have gone old. The row then shows the source with its age ("OneDrive
report 12 min ago", "Google Drive's queue, live"), and the legend explains each service's sources from the
same constants (`OneDriveProvider.reportEvery`, `ICloudProvider.checkInterval`), so the two can't drift.

### Rule 3: output you don't recognize counts as unknown

Everything an adapter reads from a client is undocumented and can change. So:
- **Match what you know, and nothing else.** OneDrive's report has five codes Velum knows; any other code
  reads "Can’t tell", with "OneDrive reported a status Velum doesn’t recognize (code 4097)". iCloud's
  `brctl status` counts as healthy only when it says both `client:idle` and `caught-up`.
- **Never fall through to healthy.** A `default:` branch, an empty string or a parse failure lands on
  `.unknown` or `nil`, never `.ok`.
- **Parse defensively.** Strip what you can't use (iCloud's parser strips terminal colour codes), look for
  the one line you need, and return `nil` when it isn't there.

### Rule 4: discover with `isLiveCloudFolder`, where only a clear yes counts

`isLiveCloudFolder(_:)` (in `SyncProvider.swift`) asks macOS whether a folder is the root of a live File
Provider domain, a signed-in account's folder. It answers:
- `true`: live;
- `false`: not live. That includes "no value", which is what leftover folders from removed accounts, and any
  plain folder, answer. Removed accounts often leave folders behind, some with a date in their name;
- `nil`: macOS couldn't be asked at all, a passing hiccup.

Only a clear yes makes a new account. On `nil`, keep an account you already knew, so a hiccup can't make a
row vanish, and don't add one you didn't. Google Drive's discovery is the pattern:

```swift
switch isLiveCloudFolder(root) {
case true?: return config                                  // live
case nil: return known.contains(config.key) ? config : nil // hiccup: keep what we knew
case false?: return nil                                    // leftover, plain folder, signed out
}
```

The other two differ for reasons of their own. OneDrive's settings files independently say which accounts
exist, so it drops an account only on a clear `false`. iCloud Drive has one fixed folder and reads the
same flag on it directly. A folder name alone is weaker evidence, so a folder-based adapter wants the clear
yes.

### Rule 5: a service is present only with a live account

Return `ProviderEvidence()` (not present) unless at least one account is live. A service that is
installed but signed out of everything, or uninstalled with its settings left behind, shows nothing rather
than an error or a "stopped" alert. Services and accounts come and go on their own: the panel keeps its
shape, and whatever is left keeps working. Write a test for it, like `PlugAndPlay.absentProvidersShowNothing`
in `GoogleDriveTests.swift`: your adapter, pointed at an empty home folder, must not be present.

### Rule 6: live evidence comes before reports

The merge puts macOS's live per-file evidence ahead of any report a service writes, and the lid line uses
only live evidence. Your adapter should follow the same order in what it reads:
- **Prefer live signals.** Google Drive's queue and its pause marker are read live, every pass. A
  report written now and then is a fallback for account-wide states that have no live signal (OneDrive's
  hourly report is the only place its "Paused" lives when its icons are hidden).
- **Check that a signal moves before calling it live.** iCloud's `brctl status` stayed "idle, caught-up"
  while a test file uploaded, so it is used only as a slow account-wide check every 10 minutes, labelled
  with its time, never as live state.
- **Leave `exactStatus` `nil`.** The client's own words are the one thing the merge puts ahead of live
  failures on the row, and `SyncState.classify` knows OneDrive's English wording only. Map what you read
  into a `ProviderReport` instead. If your service's own words are worth showing, extend `classify` and its
  tests in the same pull request, and say why its words should outrank a failing upload.

### Rule 7: optional data never changes a row's state

Storage, history and other extras are welcome, but they can't decide anything:
- they never change a row's state, the lid line or the icon;
- they go in `notes` (orange through `notesNeedAttention` when they need the eye), and service-wide in
  `trouble`;
- a full account gets a heading (`trouble`), and one alert if you set `storageFull`, never a red row.
  Google Drive sets both; iCloud Drive sets the heading only;
- when they can't be read, they keep their last value or don't show, with no reason line and no alert (set
  no `note` on their A7 check, and make it `quiet`). When their shape changes, they don't show.

Google storage follows all of this, and so does the optional Google sign-in that fills in storage when
Google Drive's own cache has none.

### Rule 8: trust an undocumented format only through a self-check

When you decode something nobody documented, find a check the data must pass and show nothing when it
fails. Google Drive caches the account's storage in a protobuf whose fields were worked out by hand
(`GoogleDriveProvider.parseStorage`). Velum shows the figures only when limit − used = remaining (a plan
with no limit shows "used" alone), which held to the byte on a real account. Any other shape gives `nil`,
and the row shows no storage rather than a wrong number. Look for an equivalent in your service: two fields
that must agree, a total that must match its parts, or a checksum.

**An undocumented file can have more than one legitimate shape.** Now and then OneDrive overwrites an
account's `SyncDiagnostics.log` with a "Sync Verification" pass: a folder-by-folder scan with no
`SyncProgressState` line. A7 first took it for a format change, and the installed app raised a false "can't
read part of OneDrive" alert. "Unknown" was the safe answer, but a false alarm still costs trust. So before
you call a shape a change, find out whether it is a known variant: watch the file through days of normal
use, not one sample. Then handle each variant you find the way OneDrive's fix does:
- recognize it (`Diagnostics.isVerification`);
- record it as fine in your checker;
- keep the last real evidence with its own date, so it still goes old on time (`OneDriveProvider.keepingStatus`);
- test all three, as `VerificationPassTests.swift` does.

### Rule 9: notice when the client changes underneath

None of these files is a promise from the vendor, and clients update themselves overnight. Card A7 checks
each internal Velum reads against what was tested (`Sources/Velum/Providers/Compatibility.swift`): when
it reads it, or at each discovery pass, about once a minute. Each adapter has a companion checker
(`OneDriveCompatibility`, `GoogleDriveCompatibility`, `ICloudCompatibility`) that builds one
`InternalCheck` per internal and hands a `CompatibilityReport` back with the evidence.

| Result | Means | What happens |
|---|---|---|
| `fine` | Reads as tested | Nothing |
| `missing` | Not there yet (a new account's first report) | Nothing: not a change, and it doesn't stop the lid |
| `unrecognized` | A value never seen (a new status code) | Your adapter reads that value as unknown. Recorded; no alert |
| `unavailable` | Can't be read right now, or not covered (a live folder no row watches) | The row says why if the check has a `note`; the lid can't say "safe" if it has `guardsLid`; no alert |
| `changed` | There, but not in the tested shape: a missing line, column, table or tool | Your adapter drops the evidence; the row says why if the check has a `note`; one alert per client release, unless the check is `quiet` |

`CompatibilityReport.record` reports; it doesn't drop anything. **Dropping the evidence is your adapter's
job:** when a check finds a changed shape, don't use what that internal says, and clear what earlier reads
left (iCloud clears its cached report), so stale evidence doesn't linger.

A checker, at minimum:
- holds the client's version (a `readVersion` closure, so tests can set it) and one `InternalCheck` per
  internal, each with a `name` the dump shows ("queue (operations table)"), the account it belongs to, a
  `phrase` for the alert ("queue") and a `note` for the row;
- words its notes in `CompatibilityText`: what broke, then what still holds ("Can’t read Google Drive 134’s
  queue · only uploads are tracked");
- has an `apply(&evidence)` that the adapter calls last in `gather`. It builds
  `CompatibilityReport(provider:version:)`, adds the checks, and calls
  `report.record(into: &evidence, logged: &logged)`, which puts the notes on the rows, attaches the report
  and writes what changed to the debug log.

Further rules:
- **A hiccup is not a change.** A locked database or a timed-out command returns `nil` from your check and
  keeps the last result (`SQLiteSchema.check` does this for SQLite).
- **`guardsLid`** for evidence the lid relies on (Google Drive's queue). While that check is neither fine
  nor missing, the lid can't say "safe".
- **`quiet`** for optional evidence (storage): no alert. Set no `note` either, so the row stays silent.
- **Some things can't be checked.** Google Drive's pause marker is an empty file whose absence is normal;
  its parent folder's check covers it.
- **Live folders nobody watches:** when your service has a second way to list its live folders (Google
  Drive's `my-drive` links, OneDrive's live `OneDrive-*` folders beside its settings), `UnwatchedRoots`
  stops the lid when one has had no row for a minute. An adapter that finds folders by name alone has
  nothing to compare, and skips it.
- **A new version alone changes nothing.** Add each version you checked to `testedVersions`, and the same
  line to the README's Requirements.

### Rule 10: observe, don't replace

- **Read-only.** Open databases with `?mode=ro` and `SQLITE_OPEN_READONLY`, and never write a client's files
  or settings.
- **No network and no credentials.** The optional Google sign-in is the one exception, off by default; a new
  adapter adds none.
- **The only things Velum does to a client** are the commands the user clicks: Start, Restart and Quit
  through `clientBundleID`.
- **Don't block `gather`.** Cache by file modification date (OneDrive's report, Google Drive's database),
  rediscover accounts about once a minute or on `force`, and run anything slow on a queue of your own with
  a lock, as iCloud runs `brctl`. Anything an outside feature plugs in (Google's `signInStorage`) must
  return cached values and never wait.
- **Log state changes, not passes.** `debugLog("yourservice", "…")` when something changes (Google Drive logs
  its queue going from empty to busy, not every count). Never log file contents, tokens or the client's
  internal account IDs.

## The three worked examples

Read them in this order. Each shows a different kind of service.

### OneDrive: the client's own reports and Accessibility text

`Sources/Velum/Providers/OneDrive/`. A client with rich files of its own, read with care.

| What it reads | For | Why this way |
|---|---|---|
| The `libraryScope` lines in each account's `.ini` under `~/Library/Application Support/OneDrive/settings/<slot>/` | Which accounts exist, their folders and web addresses | OneDrive's own record. The folder must also exist, and it is dropped on a clear "not live" (signed-out accounts leave settings behind) |
| Which settings files each OneDrive process holds open | Which process serves which account, and whether it runs | One process per account. After an update OneDrive may not hold its files yet, so there is a two-minute grace before the row says it can't tell |
| `~/Library/Logs/OneDrive/<slot>/SyncDiagnostics.log` | The account-wide report: paused, sync issue, healthy | Written about hourly, so it is a timed report with `every` of one hour: old after 75 minutes, and never green once old. Five known codes; any other reads unknown |
| `UXDatabase.db` → `history_list` | Recent activity (`keepsOwnHistory` true) | Item types Velum doesn't know are left out, never shown as "Synced" |
| The text on OneDrive's own menu bar icons, through Accessibility, opt-in | `exactStatus`: "Uploading file (58%)", "Paused" | Live and exact, but only while OneDrive's icons exist and the user has allowed Accessibility. Everything else works without it. It predates [rule 6](#rule-6-live-evidence-comes-before-reports) |

OneDrive shows the full range of A7's checks: settings, report, activity list, processes and live folders.

### iCloud Drive: a system service with no client, plus `brctl`

`Sources/Velum/Providers/iCloud/`. Part of macOS: no app to start or quit, and one slow command-line tool.

| What it reads | For | Why this way |
|---|---|---|
| `~/Library/Mobile Documents/com~apple~CloudDocs` reading as ubiquitous | Whether iCloud Drive is on | One account per Mac, key `"iCloudDrive"` |
| `Desktop` and `Documents` symlinks inside it, pointing at the real, synced home folders | Desktop & Documents, watched as extra `watchRoots` and `places` | The real files live in the home folder, with the same per-file flags |
| `/usr/bin/brctl status com.apple.CloudDocs` | The account-wide report | It takes 10 to 13 seconds and didn't change while a file uploaded, so it runs on its own queue every 10 minutes as a timed report (`every` = 10 minutes, old after 25). Healthy only with `client:idle` and `caught-up` |
| `brctl quota` | Free storage, in `notes`; "Storage full" at the heading | Optional, so its check is `quiet` and has no `note` |

What makes it different:
- `clientBundleID` and `clientRunning` are `nil`, and `versionOwner` is macOS: `brctl` ships with the
  system, so macOS's version is the one tested.
- `keepsOwnHistory` is `false`: Recent shows the iCloud uploads Velum saw finish.
- **A trap worth knowing about:** every new or edited iCloud file reports error 4355 ("couldn’t access your
  iCloud account") until its upload finishes, about 20 seconds. Counted as a failure, every save would flash
  "1 file can’t upload". `UploadTracker.isTransient` reads it as waiting; a server that is really unreachable
  shows up as the stuck alert after 10 minutes. Look for errors like this in your service.
- Its `unknownReason` and report `reason` say what Velum is doing about it: "Checking iCloud now. This takes
  about 15 seconds.", "iCloud didn’t answer the 2:45 PM check. Velum tries again at 2:55 PM."

### Google Drive: a readable local queue, a cached account record, pause

`Sources/Velum/Providers/GoogleDrive/`. One app serving any number of accounts, each with a local database.

| What it reads | For | Why this way |
|---|---|---|
| Every `~/Library/CloudStorage/GoogleDrive-<email>` folder that is live | The accounts, key `"googledrive:<email>"`, named by email | A clear yes from `isLiveCloudFolder`, so accounts come and go on their own |
| `NSRunningApplication` for `com.google.drivefs` | `clientRunning`, and `running` on every account | One process serves every account |
| `~/Library/Application Support/Google/DriveFS/<id>/`, matched to an account through its `my-drive` symlink | Each account's data | The numeric folder name is Drive's account ID: used, never shown or logged |
| `metadata_sqlite_db` → the `operations` table | Drive's queue of pending work: empty is "Up to date", rows are "Syncing changes" | Live evidence, so a report with `timed: false`. It held rows while a test file uploaded and emptied afterwards. A busy queue holds the lid and sets `workingSince`. Unreadable for over 10 seconds, the row has no status and the lid can't vouch |
| `DriveFS/user-paused`, an empty file | "Paused", for every account | Found by comparing Drive's files before and after the maintainer paused it |
| `metadata_sqlite_db` → `properties` → `driveway_account`, a protobuf | Storage: "214 GB free of 400 GB" | Shown only when limit − used = remaining ([rule 8](#rule-8-trust-an-undocumented-format-only-through-a-self-check)). Optional ([rule 7](#rule-7-optional-data-never-changes-a-rows-state)) |

Also: `keepsOwnHistory` is `false`, `.Trash` inside the folder is never tracked (a delete there isn't an
upload), and folders under `.shortcut-targets-by-id` are a `flat` place, "In a folder shared with you".
Mirror mode keeps files outside File Provider and isn't covered.

## Adding a service, file by file

When you add a `ProviderID` case, Swift's exhaustive `switch` statements point at the first four rows (six
switches in all). The rest the compiler can't see.

| File | What you add |
|---|---|
| `Providers/SyncProvider.swift` | The `ProviderID` case and raw value, `name`, `deletedFilesLabel`, `clientBundleID` |
| `Providers/Compatibility.swift` | `testedVersions` (and `versionOwner` for a system service); your row and alert sentences in `CompatibilityText` |
| `LegendView.swift` | Your line in `sourceLines`: where status comes from, and when it goes old |
| `Entry.swift` | Your service's line in the `--dump` printout. If your first check is slow, wait for it in `collectOnce`, as iCloud's `waitForFirstCheck` does |
| `Providers/<Service>/<Service>Provider.swift` | The adapter. Give it `init(home:)` and an `isLive` seam, so tests can point it at a fake home folder |
| `Providers/<Service>/<Service>Compatibility.swift` | Its A7 checker. The file name carries the service's name: one module can't hold two files with the same name |
| `Model.swift` | Your adapter in `Collector.init`'s default list. Its place there is its heading's place in the panel |
| `LegendView.swift`, `notesLines` | The Recent line names the services without their own history; check that it reads well with yours. A line for any notes you add |
| `PanelView.swift` | The empty panel's sentence names every service. Recent's hover text for uploads Velum recorded names iCloud only. The Manage Storage item is named per service in one line, if yours needs its own name |
| `UploadTracker.swift`, only if needed | A scratch-file name your client never uploads (`isSyncable`, like OneDrive's `.fetch`), or a false error during normal uploads (`isTransient`, like iCloud's 4355). Both are shared today: keep additions narrow |
| `SampleData.swift`, optional | Made-up rows, so `--render-panel --sample` can show your service without real accounts |
| `README.md` | The services named in the opening paragraphs, the Requirements line ("tested with"), a paragraph under "How Velum knows", a row per source in its table, and your service's limits |
| `Tests/VelumTests/<Service>Tests.swift` | See [Testing without anyone's data](#testing-without-anyones-data) |

A minimal adapter, for orientation. It compiled once, in this guide's dry run (with a real `ProviderID` case
in place of `.example`), but it is not a template to paste: each line needs evidence from a real Mac. If it
disagrees with `SyncProvider.swift`, the code wins.

```swift
import AppKit

/// Example as a provider. Say what was verified, on which macOS and client version, and when.
final class ExampleProvider: SyncProvider, @unchecked Sendable {
    let id = ProviderID.example
    static let folderPrefix = "Example-"

    private let cloudStorage: URL
    private var configs: [AccountConfig] = []
    private var lastDiscovery = Date.distantPast
    /// Test seam: whether a folder is the root of a live File Provider domain.
    var isLive: (URL) -> Bool? = isLiveCloudFolder

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cloudStorage = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    }

    func gather(force: Bool, now: Date) -> ProviderEvidence {
        if force || now.timeIntervalSince(lastDiscovery) > 60 {
            configs = discover(known: Set(configs.map(\.key)))
            lastDiscovery = now
        }
        guard !configs.isEmpty else { return ProviderEvidence() }        // rule 5: present only with a live account
        // nil: no app to start or stop. If the app can't be found, nil too, never a guessed false (see clientRunning).
        let running = id.clientBundleID.map { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
        }
        var evidence = ProviderEvidence(present: true, clientRunning: running)
        for config in configs {
            var account = AccountEvidence(config: config, name: config.fallbackName)
            account.running = running ?? true
            // account.report = a ProviderReport from evidence you can name, or nothing (rule 1).
            if account.report == nil {
                account.unknownReason = "Example keeps no status Velum can read. Files waiting or failing still show."
            }
            evidence.accounts.append(account)
        }
        // Required before this ships: a compatibility checker (rule 9), applied here, last.
        // Left out of this sketch; see GoogleDriveCompatibility.
        return evidence
    }

    func discover(known: Set<String>) -> [AccountConfig] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path) else { return [] }
        return names.filter { $0.hasPrefix(Self.folderPrefix) }.sorted().compactMap { name in
            let root = cloudStorage.appending(path: name, directoryHint: .isDirectory)
            let account = String(name.dropFirst(Self.folderPrefix.count))
            let config = AccountConfig(
                key: "example:" + account, provider: .example,
                folder: root, watchRoots: [root],
                places: [NamedRoot(path: root.path, name: "Example", prefixed: false)],
                fallbackName: account,
                webURL: URL(string: "https://example.com/")!, keepsOwnHistory: false)
            switch isLive(root) {                                  // rule 4: only a clear yes
            case true?: return config
            case nil: return known.contains(config.key) ? config : nil
            case false?: return nil
            }
        }
    }
}
```

## Testing without anyone's data

The repository is public. Nothing from a real account goes into it: no names, emails, file names, home
paths, account IDs, databases or logs. Tests use made-up data shaped like what you saw.

- **Run them** with `Scripts/test.sh` (Swift Testing; works with the Command Line Tools alone).
- **Paths** start at `/Users/test` (`SampleData` uses `/Users/sample`); emails are like
  `someone@example.com`. `Tests/VelumTests/Fixtures.swift` has made-up accounts and `Fixture.status(…)`,
  which runs your evidence through the real merge, so a test can assert the row's state, headline and source.
- **Parsers are `static` functions,** tested on strings shaped like real output, including garbage and empty
  output (`ICloudParsing` in `ProviderTests.swift`).
- **Files are built in a temporary folder:** an SQLite table with a few rows (`GoogleDrive.readsTheOperationsTable`),
  a symlink (`dataFoldersMatchByTheirMyDriveLink`), a folder tree under a fake home passed to `init(home:)`.
  A plain temporary folder never reads as a live File Provider domain, so it tests the leftover-folder path
  without a seam (`plainFoldersAreNotAccounts`).
- **Seams** stand in for what tests can't create. A live account can't be made in a test, so give your
  adapter an `isLive` closure and set it to `{ _ in true }`; compatibility checkers take `readVersion` and
  `isLive` the same way; `Collector(providers:)` takes any list of adapters.
- **Test the bad cases first:** an unknown code, a missing line, a renamed column, a record that doesn't add
  up, the client not running, no accounts at all. None may end `.ok`: they end unknown, absent, or "Not
  running", and bad optional data simply doesn't show. `CompatibilityTests.swift` has examples of most.
- **Captures.** To shape a fixture, look at the real output on your own Mac, then write the fixture by hand
  with every name, email, path and ID replaced. Never commit a real database, log or `--dump`. A redacting
  export is planned (card S2); until it lands, redact by hand.
- **Screenshots** come from `Velum --render-panel out.png --sample healthy` and made-up `SampleData`. A render
  without `--sample` shows your real accounts: keep it out of the repository.

## The live checklist

Every adapter passes this on a real Mac that uses the service, run by its maintainer. It is written from
what the iCloud Drive and Google Drive adapters actually did, plus the stopped-app check from the
stuck-files work. Steps marked *not yet run live* are ones no shipped adapter has recorded on a real Mac.
Velum's tests cover the logic behind them; run them live if you can. In your pull request, record each step as passed, failed or not
run, with times.

**Ground rules.** A test file written into someone's synced folder needs their yes each time. Name it
`velum-test-<time>.txt`, put it at the top of the account, and delete it only after about 75 seconds of
quiet (OneDrive restores a file deleted mid-sync). Watch with `Velum --dump` (from `.build/release/Velum`
or `build/Velum.app/Contents/MacOS/Velum`), which prints each row as the panel would show it, the
"Not in the cloud yet" list and every compatibility check. The lid line isn't in `--dump`: read it in the
panel, or turn on ••• → Debug Logging, which writes a `Lid:` line to `~/Library/Logs/Velum/Velum.log` each
time it changes.

1. **Confirm the signals before building on them.** On the real Mac, check and record:
   - FSEvents arrive inside the account's folder (iCloud: 1.8 s after a write);
   - the per-file flags are real: count the files that read as uploaded (Google Drive: 1,076);
   - transfer progress arrives, and whether it says upload or download;
   - any error macOS shows during a normal upload (iCloud's 4355);
   - leftover folders read as not live and don't appear.
2. **A test file goes waiting → uploading → uploaded.** Note when each state appears in `--dump`, then edit
   the file and watch again. iCloud: waiting at 1.9 s, uploading at 2.2 s, edited at 12 s, uploaded at 21 s.
   Google Drive: uploading at 0.4 s, uploaded at 13.6 s, its edit 10.6 s later.
3. **The lid line at each step:** "Wait before closing the lid · 1 file still on the way up" while it
   uploads, "Safe to close the lid" once it's in the cloud. *Not yet run live.*
4. **Your account-wide evidence during the test.** Does it move? Google Drive's queue went 2 → 1 → 0 rows and
   became live evidence. `brctl status` didn't move, so it became a slow check. What doesn't move with
   uploads must not be treated as live.
5. **Recent.** A service without its own history shows the test file as uploaded.
6. **Delete it, after the quiet period,** and check it stays gone and isn't recorded as an upload (Google
   Drive's `.Trash` once was).
7. **The app quit.** The account stays, and the heading says "Not running" with Start (Google Drive). A file
   written while the app is quit may read as failing ("couldn’t connect to the server"), as OneDrive's did:
   check what yours does. Then start the app again.
8. **Paused**, if the service can pause. The maintainer pauses it; compare the client's files before and
   after to find the marker. The row says "Paused", or "Paused, 2 files waiting".
9. **Compatibility.** `--dump`'s "Compatibility:" block reads "every check passes" on the version you tested.
10. **The panel itself.** The maintainer opens it, or check with `--render-panel` and keep the image private.
11. **A failing upload with the app running** (storage full, for example). The row says "can’t upload" with
    macOS's reason, and the lid line says not everything is in the cloud. *Not yet run live.*
12. **Offline.** Turn Wi-Fi off with a file waiting. It stays waiting, and the lid line doesn't say safe.
    *Not yet run live.*
13. **The app restarted with its own icons hidden,** if it draws any. The status holds without its icon
    text. *Not yet run live.*

## Maintainers

Every adapter needs a **named maintainer who uses the service every day**, on their own Mac. "Named" means
someone the project can reach, such as the author of the issue that proposed the adapter; a legal name
isn't needed. The maintainer:
- confirms the signals and runs the live checklist before the adapter ships;
- runs it again when the client updates and A7 reports a check that isn't fine;
- answers issues about the service, with their redacted `--dump` output.

That holds even for a small adapter that only lists folders, because the lid line trusts every folder an
adapter lists. A **deep** adapter goes further and reads what only the service knows: its files, databases,
tools or app. Either way, an adapter for a client nobody here uses is how wrong statuses ship, and a wrong
"Up to date" is the bug this app exists to prevent.

So a service without a maintainer gets no adapter. A generic tier (card C3) is planned to show any File
Provider folder at basic fidelity (waiting, uploading, failing), labelled beta. Until it lands, a service
without an adapter doesn't appear.

| Service | Adapter | Maintainer |
|---|---|---|
| OneDrive | deep | repository owner |
| iCloud Drive | deep | repository owner |
| Google Drive (streaming) | deep | repository owner |
| Dropbox | none yet ([card P2](plans/roadmap/cards/P2-dropbox.md)) | wanted |
| Box, Proton Drive, Nextcloud and others | none yet | wanted |

To volunteer, open an issue naming the service, the client version and your macOS version.

## The pull-request checklist

- [ ] An issue names you as the maintainer, and the client you use daily.
- [ ] `ProviderID`: a new case whose raw value will never change; `name`, `clientBundleID`, `deletedFilesLabel`.
- [ ] `watchRoots` lists only folders whose flags step 1 of the live checklist confirmed.
- [ ] Discovery uses `isLiveCloudFolder`, with only a clear yes making a new account; leftover folders don't appear.
- [ ] Not present without a live account; tested.
- [ ] Account keys are prefixed with your raw value and stable across launches.
- [ ] No `.ok` without evidence you can name. Every report has a `label` and `written`; every timed report has `every`.
- [ ] `exactStatus` stays `nil`, or `classify` is extended and tested in this pull request.
- [ ] Anything you parse reads unknown output as unknown, never healthy, and is tested with garbage and empty input.
- [ ] `unknownReason` is set whenever there is no report.
- [ ] Optional data stays in `notes`, `trouble` and `storageFull`, and changes no row's state.
- [ ] Undocumented formats pass a self-check before they're shown, and every known variant of a file (like OneDrive's verification pass) is recognized, not reported as a change.
- [ ] A compatibility checker covers every internal you read; your adapter drops what a changed check covers; `testedVersions` and the README's Requirements agree.
- [ ] Read-only: no writes to the client, no network, no credentials; `gather` doesn't block.
- [ ] Synthetic fixtures only; nothing from a real account anywhere in the diff.
- [ ] `Scripts/test.sh` passes.
- [ ] The live checklist's results are in the pull request: each step passed, failed or not run, with times.
- [ ] The legend, the panel's service names, `--dump` and the README describe the new service.
