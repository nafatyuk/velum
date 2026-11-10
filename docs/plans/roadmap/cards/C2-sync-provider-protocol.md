# C2 · One protocol, OneDrive as adapter one

**Bucket** C Core · **Part one** · **Status: planned** · **Waits for** C1 · **Runs alongside** R1 · **Feeds** A3, A4, A7, P1, C3, T1, A5, A6, S2, P4

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

_Not started._
