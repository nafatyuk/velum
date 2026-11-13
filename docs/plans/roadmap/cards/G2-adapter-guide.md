# G2 · An adapter guide

**Bucket** G Going public · **Part two** · **Status: done** November 13, 2026 (worktree branch, awaiting merge) · **Waits for** P1, P3 (both done; C3 optional) · **Runs alongside** S1, R3 · **Feeds** G3, P2, P3

## Brief

You use OneDrive, iCloud Drive and Google Drive, and all three have adapters. Dropbox, Box and the rest need people who use them. The consultant's answer is to make provider adapters the unit of contribution: publish the protocol and an adapter guide ([memo](../strategy-memo.md) §5, item 9). A deep adapter also needs a named maintainer (§6, risk 3). There are three worked examples already: OneDrive (C2), iCloud Drive (P1) and Google Drive (P3, built November 12), and C3's generic tier adds a fourth if it lands first.

Read the [campaign rules](../README.md#rules-every-card-follows) and the hand-offs of C1, C2, C3, P1, A4 and A7.

**The idea:** a recipe card for a dish you won't cook yourself. It has to work for a stranger in a different kitchen.

## Work

`docs/adapters.md`, linked from the README and a short `CONTRIBUTING.md`, covers:
- **What an adapter answers:** the protocol's methods, each with what it means and what to return when you can't tell.
- **The trust rules:**
  - never assume OK;
  - every status gets a source and an age;
  - output the adapter doesn't recognize counts as unknown;
  - a client that changes underneath (A7's pattern).
- **The three examples:** what each reads, and why.
- **Testing without anyone's data:** synthetic fixtures, and redacted captures (S2).
- **The live checklist** every adapter passes on a real Mac:
  1. A probe file goes waiting → uploading → uploaded.
  2. A failing upload.
  3. The client quit.
  4. The client restarted with its icons hidden.
  5. Offline.
  6. The lid line's verdict at each step.
  7. Probes cleaned up.
- **Maintainers:** a deep adapter needs a named maintainer who uses the client; without one it stays in the generic tier.
- **The pull-request checklist.**

## Done when

- **A dry run:** a fresh agent session, given only the guide and the repo, sketches a Dropbox adapter skeleton that compiles against the protocol. The sketch is thrown away, never committed. The session reports what the guide didn't answer, and those gaps are fixed.
- The checklist matches what P1 actually did.

## Ownership and limits

You own `docs/adapters.md` and `CONTRIBUTING.md`. Write no adapter code.

## Hand-off

Written November 13, 2026, overnight, in its own worktree (cut from `main` at `f07c78d`), alongside T1, A5, A6 and S2. Documentation only: no Swift changed.

### What was written

- **`docs/adapters.md`**, for a contributor who will never talk to the author:
  - **How an adapter fits in.** The shared live evidence every File Provider folder gives, what the adapter adds, and when `gather` runs.
  - **What an adapter answers.** A table per type (`ProviderID`, `ProviderEvidence`, `AccountEvidence`, `AccountConfig`, `ProviderReport`): what each field means, and what to return when you can't tell.
  - **How Velum merges your evidence.** `Collector.status`'s order, and the lid line's stricter rule.
  - **Ten trust rules.** Never assume OK; source and age; unknown output is unknown; `isLiveCloudFolder`, where only a clear yes counts; present only with a live account; live evidence before reports (leave `exactStatus` nil); optional data never changes a row's state; self-checks for undocumented formats; A7's checks, with what a checker must hold at minimum and that dropping evidence is the adapter's job; observe, don't replace.
  - **The three adapters** as worked examples, each as a table of what it reads, for what, and why.
  - **Adding a service, file by file.** Every file a new service touches, including the ones the compiler can't flag, plus a minimal adapter skeleton.
  - **Testing without anyone's data,** the live checklist, maintainers, and the pull-request checklist.
- **`CONTRIBUTING.md`**: what helps most, Velum's promises, build and test, style, pull requests.
- **README**: two lines, a "Contributing" heading before "License" linking both. Nothing else in the README changed.

### The live checklist, against what was actually done

It is written from P1's and P3's hand-offs, plus A3's stopped-app check, with their real timings as examples. Every step is recorded as passed, failed or not run. Four steps are tagged *not yet run live*, because no shipped adapter has recorded them on a real Mac:
- **step 3**, the lid line at each step of a test file's life: P1's Done-when asked for it, but its hand-off records only the file's states;
- **step 11**, a failing upload with the app running: P1 never observed storage full, and A3's failing file came only with OneDrive quit;
- **step 12**, offline: P1's card asked for it with the owner's help; it wasn't run;
- **step 13**, the app restarted with its own icons hidden.

The card's original list maps on as: probe → steps 2 and 3; failing upload → 11; client quit → 7; icons hidden → 13; offline → 12; the lid line → 3; probes cleaned up → 6.

### Decisions (Codex advised; the Fable consultant decided the conflicts)

Both read the same brief and the draft. Their memos stay in the session's scratchpad, not the repo.

| Decision | Codex | Fable | Built |
|---|---|---|---|
| The checklist's unrun steps | A separate "still outstanding" block; every result recorded as passed, failed or not run | One numbered list, the unrun steps tagged, since a separate block makes them look optional | Fable's list, with Codex's recording rule |
| `exactStatus` for new adapters | "Leave it nil"; any exception needs the precedence reviewed | "Leave it nil"; using it means extending `classify` and its tests in the same pull request | Both |
| The maintainers table | "The repository owner"; a named maintainer is any reachable contact, no legal name | "Repository owner" in the table | Both |
| The README link | Before License, two lines | The same | As agreed |
| The adapter skeleton | Trim it, because a commented-out checker invites copying it half done | Keep it whole: the dry run built from it. Replace the commented-out call with a "required before this ships" comment | Fable's, and the guard bug the dry run found is fixed |
| Structure | Keep the Contents list; unnumber the rules | First: drop the Contents list. On review: unnumbered sections, numbered rules, Contents kept | Fable's second ruling |
| CONTRIBUTING | Versions and expected-versus-observed in bug reports; fuller redaction; tests where relevant | Cut the Liquid Glass line; "One maintainer: replies can take a few days"; the home path in the redaction | Both |
| Planned work | "Planned", and say `--redact` doesn't exist yet | The same, and qualify "for free" | As agreed |

The dry run raised three more calls, which Fable ruled on:
- **Flags before folders.** The lid line trusts every watched folder. So no adapter that lists a folder in `watchRoots` is merged until step 1 of the live checklist has confirmed its flags on a real Mac. There is no code switch for "unverified".
- **Every adapter needs a maintainer,** not just a deep one. A deep adapter is one that reads what only the service knows: its files, databases, tools or app. Even an adapter that only lists folders puts them under the lid, so unmaintained services wait for C3's planned tier.
- **An app that can't be found:** `clientRunning` is `nil`, never a guessed `false`, and never silent: the checker records an `unavailable` check with a row note. The guide says the shipped adapters predate this advice.

Both consultants also corrected facts in the draft, all fixed:
- the first Google Drive fallback's real wording;
- what `quiet`, `guardsLid` and `unavailable` really do;
- that `record` drops nothing;
- that iCloud sets no `storageFull`;
- "Paused, 2 files waiting";
- the unlimited-plan exception to Google storage's self-check;
- the stop alert's two-minute grace;
- that only non-empty `exactStatus` wins;
- iCloud's unprefixed key;
- that `--dump` doesn't print the lid line (the debug log's `Lid:` line does);
- the `@State` wording.

### The dry run

A fresh agent, given only the guide and a scratch copy of the repo and told to stay out of `docs/plans/`, sketched a Dropbox adapter. It wrote a provider, a checker, the `ProviderID` case and every edit in the guide's file table, plus ten synthetic tests, with each Dropbox fact marked `UNVERIFIED`. It never needed `docs/plans/`. The guide's file table covered all six exhaustive switches.

What it found, and what changed:
1. The checker's minimum shape → now in rule 9.
2. Empty `testedVersions` → "Never empty".
3. An app that can't be found → the `clientRunning` row (Fable's ruling).
4. "For free" against "confirm first" → flags before folders.
5. When `UnwatchedRoots` applies → rule 9.
6. A key with no identity in the folder name → the `key` row.
7. No `isLive` seam on adapters → the skeleton and the testing section.
8. Curly apostrophes in quoted UI strings → fixed throughout.
9. Which test proves rule 5 → write your own, like `PlugAndPlay`.
10. Parser checks for an adapter that parses nothing → "anything you parse".
11. Places the table missed: the empty panel's sentence, Recent's hover text, the legend's Recent line and the README's opening → added.
12. "Deep" undefined → defined.
13. `/Users/sample` in `SampleData` → noted.

**Compile.** The sketch, and the guide's own skeleton copied verbatim beside it (pointed at the sketch's Dropbox case), went through the queue in the scratch copy as `velum-g2-dropbox-sketch`. Result: pending when this was first committed; see the next commit. Nothing from the dry run is committed.

### Found in passing, for the owner and other cards

- **Code that doesn't yet follow the guide's advice.** These are follow-ups; the guide says the shipped adapters predate the advice where it matters.
  - Google Drive reports `clientRunning` `false` whenever no process matches, even if the app can't be found.
  - OneDrive's icon text outranks live failures (already A7's follow-up 2).
  - Recent's hover text for uploads Velum recorded says "iCloud entries" for Google Drive too (`PanelView.swift`, `helpText`).
  - The legend's Recent line joins three or more services with " and " each time (`LegendView.notesLines`; `CompatibilityText.list` does it properly).
  - iCloud sets no `storageFull`, so a full iCloud raises no alert (already A4's follow-up).
- **Stale test expectations at `f07c78d`.** Four expectations still used headlines A4 retired: "No status yet" (`GoogleDriveTests.swift:137`, `CompatibilityTests.swift:177`, `:373`) and "Status unknown" (`CompatibilityTests.swift:156`). The wave 2 queue run failed on exactly those four (164 tests, 4 issues), so its chained install didn't run. The main session fixed them on `main` at `3c3e311`.

### Added at the supervisor's request: known variants are not changes

Found live on November 13: now and then OneDrive overwrites an account's `SyncDiagnostics.log` with a "Sync Verification" pass, which has no `SyncProgressState` line. A7 took it for a format change, and the installed app showed a false "can't read part of OneDrive" alert. The fix is on `main` at `ff5fe68`: `Diagnostics.isVerification`, `OneDriveProvider.keepingStatus` (keeps the last real report, with its own date), the compat check recording the pass as fine, and `VerificationPassTests.swift`.

The guide's rule 8 now has a short paragraph and the pull-request checklist one line: an undocumented file can have more than one legitimate shape, so find out whether a shape is a known variant before calling it a change. The guide cites those names, which exist once this branch is merged onto `main`.
- **The roadmap README's G2 row** still says "planned". It was left alone so the parallel cards' rows merge cleanly; update it at merge.

### What changed since this card was written (November 12)

- **Ready to start.** The three adapters show the full range:
  - a client with its own reports and Accessibility text (OneDrive);
  - a system service with no client and a slow command-line check (iCloud, `brctl`);
  - a client with a readable local queue and cached account record (Google Drive).
- **Patterns the guide should teach:**
  - `isLiveCloudFolder` for discovery: leftover folders answer "no value", so only a clear yes counts;
  - live evidence before reports;
  - a service is present only with a live account;
  - `clientBundleID` for Start, Restart and Quit;
  - `deletedFilesLabel`;
  - optional data, like storage, never changes a row's state, the lid line or the icon;
  - undocumented formats are trusted only through a self-check, like Google storage's limit − used = remaining.
