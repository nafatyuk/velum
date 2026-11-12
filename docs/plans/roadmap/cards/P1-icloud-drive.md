# P1 · iCloud Drive

**Bucket** P Providers · **Part two** (pulled forward at the user's request) · **Status: built** November 12, 2026; live check after install · **Waits for** C2 · **Runs alongside** C3, T1, A5, A6, S2 · **Feeds** S1, G2, G3

## Brief

iCloud Drive draws no menu bar icon at all [V], so the only place to see whether it is syncing is buried in Finder's sidebar. The consultant put it first among new providers ([memo](../strategy-memo.md) §2, "Next", item 1), on two facts it verified on this Mac:
- the per-file flags return real values in `~/Library/Mobile Documents/com~apple~CloudDocs`;
- `/usr/bin/brctl status` runs without special privileges.

`brctl`'s output is undocumented and noisy: parse it defensively. The launch waits for this card (G3), because "every cloud, one icon" needs a second cloud.

Read the [campaign rules](../README.md#rules-every-card-follows), [C2's hand-off](C2-sync-provider-protocol.md#hand-off) (the protocol, and its sketch of how iCloud fits), [A4's](A4-legend-and-why-unknown.md) and [A7's](A7-onedrive-update-check.md) cards.

**The idea:** the second plug in C2's socket. If iCloud fits without bending the socket, the socket is right.

## Work

- **Find out first,** and record each answer in the hand-off:
  1. Does FSEvents deliver changes inside `Mobile Documents`?
  2. Do File Provider's progress subscriptions report iCloud transfers?
  3. With Desktop & Documents in iCloud turned on, where do those folders really live, and are their flags the same?
  4. What does `brctl status` print while idle, uploading, offline, and with storage full? Capture the shape only. Redact names before anything is written down.
  5. Which upload error does a full iCloud storage give?
  6. How much does one `brctl status` run cost, and so how often may Velum run it?
- **The adapter,** in `Providers/iCloud/`.
  - Discovery: iCloud Drive is on when the CloudDocs folder exists and reads as ubiquitous. Its display name is "iCloud Drive".
  - Running: there is no client to quit, and signed out or iCloud Drive off counts as "not available".
  - The tracker's filters: `.icloud` placeholders, as well as the shared filters.
  - The report: `brctl status`'s account-wide state, with the time it ran, parsed defensively. Output it doesn't recognize is ignored and reported, never read as healthy.
  - Actions: Open in Finder; open iCloud.com; open System Settings at iCloud.
- **Storage full is the important error.** When uploads fail for lack of space, say so plainly ("iCloud storage is full: 3 files can't upload"), in the row, the lid line and the alert.
- **The lid line, alerts and stuck files** (A1, A2, A3) cover iCloud with no special cases. If they need one, the protocol is wrong: fix it in C2's files, with the user's OK.

## Done when

- Tests cover:
  - `brctl` parsing on synthetic samples shaped like the captures, including garbage and empty output;
  - discovery when iCloud Drive is off.
- A live check on this Mac, with the user's yes:
  1. A probe file in iCloud Drive shows waiting → uploading → uploaded in `Velum --dump` and in the panel.
  2. The lid line follows it.
  3. The probe is deleted once it has settled.
- With the user's help, offline: Wi-Fi off makes the probe wait and the lid line say so.

## Ownership and limits

You own `Providers/iCloud/` and its tests. Don't touch the OneDrive adapter. Never read or show the Apple ID.

## Hand-off

Built November 12, 2026, with C2, at the user's request ("add iCloud … I would like that very much").

### Answers to "find out first" (this Mac, macOS 27.3)

1. **FSEvents** delivers changes inside `Mobile Documents`: a probe's creation arrived 1.8 s later.
2. **File Provider progress** reports iCloud uploads at the folder root without a kind (`fileOperationKind` nil), like OneDrive's. `TransferMonitor` counts it as unlabelled ("Syncing changes").
3. **Desktop & Documents:** `~/Desktop` and `~/Documents` are the real synced folders, and they carry the same flags. `com~apple~CloudDocs/Desktop` and `/Documents` are symlinks to them, marked excluded from sync. So all three folders are watched, and "Desktop & Documents included" shows only when the symlinks point at real, synced folders.
4. **`brctl status`** runs without privileges but takes 10–13 s, even with one container named. During a probe's upload it stayed at `client:idle … caught-up`, with last-sync yesterday. So it reflects nothing live: it is used only as a slow account-wide check, every 10 minutes, labelled "iCloud status, <time>". It counts as healthy only with client idle and caught up; anything else reads "Status unknown". `brctl quota` is instant and prints "N bytes of quota remaining in personal account".
5. **The storage-full error** was not observed. `NSUbiquitousFileNotUploadedDueToQuotaError` is treated as a real failure. Quota at or below 0 shows "iCloud storage is full" on the row and "Storage full" at the iCloud heading.
6. **A trap: a false error during every upload.** A new or edited file carries error 4355 (`NSUbiquitousFileUbiquityServerNotAvailable`, "Couldn't access your iCloud account") from the moment it's written until its upload finishes, about 20 s for a tiny file here. If that counted as a failure, every save would flash "1 file can't upload". `UploadTracker.isTransient` reads 4355 as waiting; a server that is really unreachable shows up as the stuck alert after 10 minutes. The 25 `.DS_Store` files carrying 4355 permanently are already filtered by name.

The probe (with the user's yes):
- created at 0 s, read as waiting with 4355 at 1.9 s, uploading at 2.2 s;
- edited at 12 s;
- uploaded at 21 s;
- deleted after 75+ s of quiet.

Other facts:
- Per-file flags read without an entitlement: 1,144 files uploaded, of which 551 were not downloaded.
- 81 containers sit in `Mobile Documents`. Only `com~apple~CloudDocs` is iCloud Drive; app containers aren't watched.

### What was built

- **`Providers/iCloud/ICloudProvider.swift`:**
  - Discovery: the CloudDocs root reads as ubiquitous; Desktop & Documents as above; checked every 60 s.
  - Account key "iCloudDrive", name "iCloud Drive", `clientRunning` nil (nothing to start or quit).
  - Actions: Open in Finder (iCloud Drive), View Online (icloud.com/iclouddrive), and "iCloud Settings…", which opens System Settings → Apple Account. The direct iCloud anchor wasn't found.
  - `keepsOwnHistory` false.
  - Background `brctl` with timeouts; `parseStatus` and `parseQuota` are static and tested.
- **Recent includes iCloud uploads Velum saw finish** (the user's choice):
  - The tracker records an upload only if it saw the file pending first, so a download landing or a rename doesn't count.
  - It keeps the last 30, saved in the defaults key `recentUploads`, as `Activity` with kind 5.
  - Their help text says they're uploads Velum saw while it was running.
  - Uploads that finish before the first check (under about a second) aren't recorded. iCloud's take about 20 s, so this rarely matters.
- **The panel**, after Codex and the Fable consultant were asked:
  - **The decision.** Fable recommended per-service headings; Codex recommended one list with "OneDrive · Personal" titles. Headings won: the user said the panel can grow, and they give service-wide problems a place.
  - **Shared points** from both: the title "Cloud Sync", text-only identity with no logos, a fixed row order, and Recent naming the row.
  - **Headings** use the "Recent" style, sentence case. A stopped OneDrive shows "Not running" and Start at its heading instead of the bottom banner; iCloud shows "Storage full".
  - **Rows** gained a notes line ("Desktop & Documents included · 1.27 TB free").
  - **Height:** 662 pt with two OneDrive accounts, iCloud and six Recent items, measured with `--render-panel`.
- **The menu bar** keeps one plain cloud, badged with the worst state across services (the user's choice).

### Left for later

- **A height cap** (Codex): pin the header and lid line and scroll the rest when the panel is taller than the screen. It isn't needed at 662 pt.
- **A4's legend** should say that iCloud's Recent shows only uploads Velum saw (Fable's risk 3).
- **The live check after install:** a probe file shows waiting → uploading → uploaded in the panel, the lid line follows it, and it appears in Recent.
