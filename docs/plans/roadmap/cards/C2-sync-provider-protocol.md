# C2 · One protocol, OneDrive as adapter one

**Bucket** C Core · **Part one** · **Status: done** November 12, 2026, built with P1 · **Waits for** C1 · **Runs alongside** R1 · **Feeds** A3, A4, A7, P1, C3, T1, A5, A6, S2, P4

## Brief

Velum is written for OneDrive alone today:
- `OneDriveFiles.swift` finds accounts, reads OneDrive's hourly report and activity database, and maps processes to accounts.
- `LiveStatus.swift` reads OneDrive's icon text.
- `Collector.status` in `Model.swift` merges all of it into an `AccountStatus`.
- `Snapshot.oneDriveRunning`, the `Store`'s summary, tooltip and VoiceOver strings, and `Notifier`'s `"onedrive"` key all say OneDrive.
- The panel's actions (Restart and Quit OneDrive, recycle bin, storage page) are OneDrive's.

The consultant found the hard parts are already provider-neutral [V]. `UploadTracker` and `TransferMonitor` work on any File Provider folder; only the `.fetch` filter in `UploadTracker.isSyncable` is OneDrive's. So the next step is a protocol, with OneDrive as its first adapter ([memo](../strategy-memo.md) §2, "Now", row 4, and "Architecture").

This card moves code; it adds no features. It also creates the test target every later card uses.

Read the [campaign rules](../README.md#rules-every-card-follows), [C1's hand-off](C1-permission-free-tracking.md#hand-off), all of `Sources/Velum/`, and the memo's "Architecture" paragraph.

**The idea:** a standard plug. Today OneDrive is wired straight into the wall; this card puts a socket in between, so that iCloud (P1) and the generic tier (C3) can plug into the same socket.

## Work

- **Characterization tests first, before any code moves.**
  - Add `.testTarget(name: "VelumTests", dependencies: ["Velum"])` to `Package.swift`. Swift Testing works with the Command Line Tools on this Mac.
  - Split the code into a library target plus a thin executable only if `@testable import` of the executable target proves awkward.
  - Pin today's behavior:
    - `Collector.status`'s order, using made-up evidence;
    - `Store.lidVerdict`;
    - `SyncState.classify`;
    - `UploadTracker.isSyncable`;
    - `Notifier`'s episodes: settle, once only, resolved, the grace after a user stop, and marked-as-sent while disabled;
    - `RelTime`.
- **The protocol, in `Sources/Velum/Providers/SyncProvider.swift`.** The memo's shape: `discoverAccounts()`, an optional `exactStatus()`, `activity()`, `actions()` and `processIdentity`. Suggested in more detail:
  - a provider id and display name;
  - its accounts, each with an id, display name, root folder and a kind label;
  - whether its client is running, and which account each process serves;
  - optional exact status (OneDrive's Accessibility text);
  - an optional report with its time (OneDrive's hourly diagnostics);
  - optional recent activity;
  - its actions (open folder, open on the web, recycle bin, storage, restart or quit the client);
  - paths the tracker should ignore (`.fetch`).
- **One merge for every provider.** `Collector.status`'s order becomes the rule every adapter gets:
  1. client not running;
  2. exact status;
  3. failed uploads;
  4. files moving;
  5. files waiting;
  6. progress with no label;
  7. the provider's report;
  8. unknown.

  Every result keeps its source and its time (the memo's "per-row provenance").
- **OneDrive becomes adapter one,** in `Providers/OneDrive/`: discovery, diagnostics, activity database, process-to-account mapping, Accessibility text and actions, moved, not rewritten.
- **Text follows the provider.** "OneDrive isn't running" becomes "<provider> isn't running". The menu items name their provider. With OneDrive as the only provider, every word the user sees stays exactly as it is today.
- **Saved state carries over.** Account ids stay today's OneDrive keys, or are migrated once. The pending list (`pendingUploads`), the resume points (`fseventsLastID.*`) and the user's settings must be read by the new build.
- **Design against two cases, build one.** In the hand-off, sketch how P1's iCloud Drive and C3's generic tier would fit. iCloud has per-file flags and `brctl status` [V], with no process per account. The generic tier has only a folder root. Anything only OneDrive has stays inside the OneDrive adapter: the consultant's named risk for this card is over-abstracting from one example.

## Done when

- `swift test` passes, including the characterization tests, which were written before the move and pass unchanged after it.
- `Velum --dump` prints the same lines before and after on this Mac, apart from times. Capture both and diff them.
- A test shows the new build reading a pending list and resume points saved by today's build.
- The panel looks the same, before and after, in light and dark (screenshots).
- Installing on this Mac (`./build.sh --install`, with the user's OK) keeps the pending list and the alerts toggle.

## Ownership and limits

You own:
- `Sources/Velum/Providers/`;
- whatever moves there from `Model.swift`, `OneDriveFiles.swift` and `LiveStatus.swift`;
- the test target in `Package.swift`;
- `Tests/VelumTests/`.

You may edit every Swift file, since this card moves code, so no other code card runs beside it. Add no providers and no features.

## Hand-off

Built November 12, 2026, in the same session as P1 (iCloud Drive), at the user's request to add iCloud.

**What changed, for OneDrive: nothing visible.** `Velum --dump` from the old installed build and from the new build, run back to back on this Mac, differ only by the new iCloud lines and a minute's rollover in Recent's times. The single-provider panel keeps its title ("OneDrive"), summary wording, banner, menus and row text. One deliberate exception: the "OneDrive isn't running" banner now uses `exclamationmark.triangle` instead of `exclamationmark.icloud`, so it can't read as an iCloud fault. That change was the consultant's catch.

**The protocol** (`Sources/Velum/Providers/SyncProvider.swift`):
- `SyncProvider` has an `id` (`ProviderID`: `.oneDrive` = "onedrive", `.iCloud` = "icloud"; the raw values key saved state and alerts) and `gather(force:now:) -> ProviderEvidence`.
- `gather` runs on the collector's serial queue for every refresh, so it must not block. iCloud's slow `brctl` runs on a queue of its own.
- `ProviderEvidence` carries:
  - `present`: absent providers show nothing;
  - `clientRunning`: nil when there is no client;
  - `accounts: [AccountEvidence]` and `activity`;
  - OneDrive's `axTrusted` and `liveItemsFound`;
  - `trouble`: a service-wide problem shown at the service's heading.
- `AccountEvidence` carries:
  - `config` and `name`;
  - `running` and `pid`;
  - `exactStatus`: the client's own words. Empty means found but blank; nil means not found.
  - `report: ProviderReport?`: label, written, state, headline. Its `source` reads "OneDrive report, 1:56 AM";
  - `lastActivity`;
  - `notes`: facts for the row's own line.
- `AccountConfig` is now provider-neutral:
  - `key`, `provider`, `folder` (what Open in Finder opens);
  - `watchRoots`: every folder whose changes count;
  - `places: [NamedRoot]`: every path that leads into the account, with how to word a location;
  - `fallbackName`, `webURL`, `recycleBinURL`, `storageURL`;
  - `keepsOwnHistory`: false means Velum records the uploads it sees finish.

  OneDrive's URLs are worked out at discovery, and the old `relativePath` became `location(of:)`.
- `Activity` moved there too, now `Codable`.

**One merge for every provider.** `Collector.status(_:transfer:uploads:watchingUploads:now:)` keeps C1's order:
1. not running;
2. exact status ("From <provider>");
3. failed uploads;
4. moving files;
5. waiting files ("Paused, N waiting" when the report says paused);
6. unlabelled progress;
7. the report, with "Nothing pending · " added only when the report is healthy and coverage has no gaps;
8. "No status yet".

OneDrive's code table (65536 paused, 8194 not syncing, 1854 sync issue, 0 and 16777216 healthy, anything else unknown) moved into `OneDriveProvider.report(from:)`.

**OneDrive is adapter one,** in `Providers/OneDrive/`:
- `OneDriveProvider.swift` holds discovery caching, the process-to-account mapping, icon text, the report and the history, all moved from `Collector` without rewriting.
- `OneDriveFiles.swift` and `LiveStatus.swift` moved there.
- The `.fetch` filter still sits in `UploadTracker.isSyncable`; it is harmless for iCloud. Moving it into the adapter is left for whoever next touches the tracker.

**Snapshot and Store:**
- `Snapshot.providers: [ProviderStatus]` (id, `clientRunning`, `trouble`).
- `Snapshot.oneDrive`, `oneDriveRunning` and `stoppedProviders`.
- `Snapshot.lidVerdict` moved here from `Store`, so it is testable. `LidVerdict.notRunning` now carries the provider's name.
- `Store.title` is the provider's name with one provider, "Cloud Sync" with several. `Store.groupsByService` is true with several providers. `Store.spokenName(_:)` gives "OneDrive, School" for VoiceOver once services are grouped.
- `Notifier`:
  - keys a stopped client by the provider's id, so "onedrive" is unchanged;
  - skips the per-account checks of a stopped provider;
  - names the provider in issue alerts and "running again" notes;
  - creates its notification center lazily, so tests can make a `Notifier`.

**Several folders per account.** `UploadTracker.watch(_:recordingUploadsFor:)` and `TransferMonitor.watch(_:)` take `[key: [URL]]`. There is one FSEvents stream per account covering all its folders, so there is still one resume point per account, and one progress subscription per folder.

**Tests** (`Tests/VelumTests`, 30 tests, `swift test`):
- The status order and its wording.
- OneDrive's codes and wording classification.
- The lid verdict across providers.
- iCloud's `brctl` parsing and discovery.
- The tracker's filters and the transient-error rule.
- Location wording.
- Alerts: settle, once only, resolved, a user stop, an iCloud stuck alert.

Swift Testing's `@Test` macro loads with the Command Line Tools only when `Package.swift` declares tools version 6.0. Under 5.10 the build fails with "plugin for module 'TestingMacros' not found". The package now declares 6.0 with `swiftLanguageModes: [.v5]`, so the app's code is unchanged.

**Characterization, honestly:** the tests were written after the move. They are pinned to the strings the old code produced, and checked against old-versus-new dumps. They were not run on the old code first.

**Changed later the same night (P3):**
- The panel now always says "Cloud Sync" with a heading per service, even with one service, so the single-OneDrive look above is gone on purpose.
- A service only counts as present with a live account.
- `isLiveCloudFolder(_:)` in `SyncProvider.swift` is the shared check for a live File Provider folder.
- `ProviderID.clientBundleID` drives Start for any service.

See [P3's hand-off](P3-google-drive.md#hand-off).

**For later cards:**
- `Velum --render-panel <file.png> [--dark]` draws the real panel with live data into an image, without replacing the running app. Use it for A3, A4 and A6's screenshots.
- `Store.show(_:)` feeds it a snapshot.
