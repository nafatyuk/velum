# Roadmap campaign: task cards

[All plans](../README.md) · [The consultant's memo](strategy-memo.md), the source of every card here.

November 10, 2026. Velum merges OneDrive's per-account menu bar icons into one icon and one Liquid Glass panel. Since this week it also answers "is everything in the cloud?" from macOS's own per-file sync flags, with no permissions needed. On November 10 a senior-consultant review set where Velum goes next. The review was a Fable agent sending out Haiku research scouts. Its answer: **the one sync-status light for a Mac**. That means one native icon that says whether every cloud folder is safe, whichever client syncs it, without replacing any client: "observe, don't replace; merge, don't hide."

This campaign turns every item in that memo into a card:
- the roadmap's Now, Next and Later;
- the ten ranked feature ideas;
- positioning, distribution and the launch;
- a mitigation for each of the five risks.

The few items it deliberately doesn't build are under [Left out on purpose](#left-out-on-purpose).

- [Strategy memo](strategy-memo.md): thesis, roadmap, ranked features, positioning, distribution, risks. Its evidence marks:
  - **[V]** verified by the consultant;
  - **[S]** a scout's report with sources;
  - **[U]** unverified.

  Cards keep the marks. Anything marked [S] or [U] is the first thing to check, not a fact to build on.

Each card is one session's work. Paste a card's "Brief" into a new session; it stands on its own.

## Progress (November 12, 2026)

**6 of 25 cards done.** Three came from the memo's "start this week":
- C1, permission-free tracking (`0a85400`);
- A1, the "Safe to close the lid?" line (`d09e180`);
- A2, problem alerts (`d09e180`).

Three were added on November 12, at your requests:
- C2, the provider protocol;
- P1, iCloud Drive, pulled forward from part two;
- P3, Google Drive in streaming mode, built overnight with your "plug-in-and-out-able" rule applied to everything.

All three were live-checked in the installed app. The panel now groups accounts under a heading per service, a layout chosen after Codex and the Fable consultant weighed in (see [P1's hand-off](cards/P1-icloud-drive.md#hand-off)).

The fourth "this week" item, Developer ID enrolment, is R1 and waits on your decision. The app icon is on hold at your word; it holds up only G1 and G3.

## How it works, in one picture

```text
                       cloud folders on this Mac
   OneDrive (any number       iCloud Drive        any other folder under
   of accounts)                                   ~/Library/CloudStorage
          │                         │                        │
   OneDrive adapter           iCloud adapter          generic tier (beta)
   (C1 built it, C2 moves it)     (P1)                      (C3)
          └────────────── SyncProvider protocol (C2) ────────┘
                                    │  each folder's status, with its source and age
                                    ▼
                              Velum's Store
       ┌─────────────┬──────────────┼──────────────┬──────────────────┐
   icon + panel    alerts       lid line      velumctl JSON     Control, widget,
   A3 A4 A6        A2 A5          A1             T1             Shortcuts (T2, T3)
```

It's like a fire panel in an office building. Every floor has smoke detectors from a different maker (the sync clients). The panel replaces none of them: it reads every detector and shows one light at the front desk.

- **C2's protocol** is the standard plug that every detector's wire fits.
- **The P cards** are deep wires for particular makers, which read everything the maker exposes.
- **C3's generic tier** is a basic wire that fits any detector built on Apple's File Provider, with no special knowledge of its maker.

## Parts

The campaign follows the memo's three horizons.

- **Part one: Now** (the next few weeks): the provider-neutral core, the assurance features that build on what already works, and signed releases. Cards: C1–C2, A1–A4, A7, R1–R2.
- **Part two: Next** (one to three months): more clouds, scripting, the rest of assurance, support, Homebrew and going public. Cards: C3, P1–P3, A5–A6, T1, S1–S2, R3, G1–G3.
- **Part three: Later**, built only when real users ask for it (risk 5, scope creep). Cards: T2, T3, P4.

## Buckets

| Bucket | What it covers | Cards |
|---|---|---|
| **C** Core | One provider-neutral engine: the permission-free tracking; a `SyncProvider` protocol with OneDrive as adapter one; a generic tier for any File Provider folder | C1 ✓ → C2 · part two: C3 |
| **A** Assurance | What turns Velum from an icon tidier into sync assurance: the lid line, alerts, stuck files by name, a legend that explains every state and its age, a check that OneDrive's internals still read as expected; then a warning before sleep and a history of each account's syncing | A1 ✓, A2 ✓, A3, A4, A7 · part two: A5, A6 |
| **P** Providers | Deep adapters: iCloud Drive first; Dropbox and Google Drive only with a named tester; OneDrive's icon text in other languages | part two: P1 · gated: P2, P3 · later: P4 |
| **T** Tools and system surfaces | `velumctl` text and JSON for scripts, Raycast and backup jobs; then Shortcuts, a Control Center control and a widget | part two: T1 · later: T2, T3 |
| **S** Support | A guided first run; a diagnostics export that redacts itself | part two: S1, S2 |
| **R** Release | Developer ID signing, a notarized DMG, Sparkle updates, a Homebrew tap | R1 → R2 · part two: R3 |
| **G** Going public | The public repo page, an adapter guide for contributors, the launch | part two: G1, G2 → G3 |

## Cards

### Part one: Now

| Card | Result | Waits for | Runs alongside | Status |
|---|---|---|---|---|
| [C1 · Permission-free tracking as the product](cards/C1-permission-free-tracking.md) | Status from FSEvents, File Provider's per-file flags, transfer progress and OneDrive's own files. Accessibility is an opt-in extra. Every status says where it came from, and nothing says "Up to date" without evidence | nothing | nothing | **done** (`0a85400`) |
| [A1 · "Safe to close the lid?"](cards/A1-safe-to-close-the-lid.md) | One line at the top of the panel: safe, N files on the way up, some can't upload, or Velum can't vouch | C1 | A2 | **done** (`d09e180`) |
| [A2 · Problem alerts](cards/A2-problem-alerts.md) | An alert for failing uploads, a sync issue, uploads stuck for 10 minutes, or OneDrive stopping. A problem must last 30 s; it alerts once, then sends one "resolved" note. Velum's own banner stands in until R1 | C1 | A1 | **done** (`d09e180`); system notifications wait for R1 |
| [C2 · One protocol, OneDrive as adapter one](cards/C2-sync-provider-protocol.md) | A `SyncProvider` protocol, with OneDrive moved behind it and nothing visible changed. A test target pins today's behavior | C1 | R1 | **done** (November 12, with P1) |
| [A3 · Stuck files, by name](cards/A3-stuck-files.md) | Files waiting or failing past a threshold, listed in the panel with Show in Finder; the stuck alert names the first one | C2 | A4, A7, R2 | planned |
| [A4 · What each light means, and how old it is](cards/A4-legend-and-why-unknown.md) | An icon legend. A "why is it unknown?" row saying what would make the status known. The age on every status, and old evidence shown as old | C2 | A3, A7, R2 | planned |
| [A7 · Notice when OneDrive changes underneath](cards/A7-onedrive-update-check.md) | At launch and whenever OneDrive's version changes, each OneDrive internal Velum reads is checked against a tested-version note. Anything that no longer reads is dropped as evidence, with a reason, and the status degrades to unknown | C2 | A3, A4, R2 | planned |
| [R1 · Developer ID and a notarized DMG](cards/R1-developer-id-and-notarized-dmg.md) | Signed with your Developer ID and the hardened runtime. The app and the DMG are both notarized and stapled, with `spctl` as the gate. Real macOS notifications switch on | your enrolment | C2 | planned; **waits on your decision** |
| [R2 · Updates through Sparkle](cards/R2-sparkle-updates.md) | Sparkle with an EdDSA key, an appcast, a `RELEASING.md` modelled on Crisp's, and a GitHub Release per version | R1 | A3, A4, A7 | planned |

### Part two: Next

| Card | Result | Waits for | Runs alongside | Status |
|---|---|---|---|---|
| [P1 · iCloud Drive](cards/P1-icloud-drive.md) | iCloud Drive as adapter two: per-file flags plus `brctl status`, parsed defensively. The lid line, alerts and stuck files work for it | C2 | C3, T1, A5, A6, S2 | **done** November 12 (pulled forward at your request) |
| [C3 · Any CloudStorage folder (beta)](cards/C3-any-cloudstorage-folder.md) | Every live root under `~/Library/CloudStorage` (Dropbox, Google Drive streaming, Box, Proton, Nextcloud…) at basic fidelity, labelled beta, leftover folders ignored | C2 | P1, T1, A5, A6, S2 | planned |
| [T1 · `velumctl`](cards/T1-velumctl.md) | A command-line tool inside the app: `velumctl status`, `lid` and `pending`, as text or `--json`, with exit codes for scripts | C2 | P1, C3, A5, A6, S2 | planned |
| [A5 · A warning before sleep or shutdown](cards/A5-sleep-and-shutdown-guard.md) | Sleep, log out or shut down with uploads pending, and Velum says so; it never blocks | C2, A1, A2 | P1, C3, T1, A6, S2 | planned |
| [A6 · Sync history per account](cards/A6-sync-history.md) | A small sparkline per account over the last days (uploads, waits, failures), so silent multi-day stalls become visible | C2 | P1, C3, T1, A5, S2 | planned |
| [S2 · Diagnostics export, redacted](cards/S2-diagnostics-export.md) | One menu item, and `Velum --dump --redact`, that writes a report with names, emails, folders and file names replaced, ready to attach to an issue | C2 | P1, C3, T1, A5, A6 | planned |
| [S1 · A guided first run](cards/S1-guided-first-run.md) | On first launch, Velum shows which clouds it found and which vendor icons still show. It deep-links to System Settings → Menu Bar and explains where its own icon landed | C3, P1 | G2, R3 | planned |
| [G2 · An adapter guide](cards/G2-adapter-guide.md) | `docs/adapters.md`: the protocol, OneDrive and iCloud as worked examples, the trust rules, and a test checklist a contributor can follow | C3, P1 | S1, R3 | planned |
| [R3 · A Homebrew tap](cards/R3-homebrew-tap.md) | `brew install --cask nafatyuk/tap/velum` from your own tap; the main Homebrew cask later | R2 | S1, G2 | planned |
| [G1 · The public repo page](cards/G1-public-repo-page.md) | A README led by the OneDrive multi-account pain, plus a screenshot and a 20-second GIF. Issue templates ask for S2's redacted report, and a Sponsor button. Then the switch to public, at your word | app icon, R2, S2 | S1, G2, R3 | planned; **your decisions** |
| [G3 · Launch](cards/G3-launch.md) | Drafts for r/macapps, Show HN and replies in the OneDrive-icon threads the scouts found. You post them | G1, R3, P1 | nothing | planned |
| [P2 · Dropbox, deep](cards/P2-dropbox.md) | Dropbox's own state beyond the generic tier: paused, the account's status, its own errors | C3, a named tester | P3 | **gated** on a tester |
| [P3 · Google Drive, deep](cards/P3-google-drive.md) | Google Drive's own state: per-file flags, its own queue of pending work, any number of accounts. Mirror mode is left for later | C2 (you maintain it) | P2 | **done** for streaming, November 12 |

### Part three: Later (only on real user requests)

| Card | Result | Waits for | Runs alongside | Status |
|---|---|---|---|---|
| [T2 · Ask Shortcuts "Is everything synced?"](cards/T2-app-intents.md) | App Intents: Is Everything Synced, Files Not in the Cloud, Open Velum; a spike first | T1, R1, Xcode | T3, P4 | later |
| [T3 · A Control and a widget](cards/T3-control-and-widget.md) | A Control Center and menu bar Control plus a desktop widget showing the one light, fed by a shared snapshot | T1, R1, Xcode | T2, P4 | later |
| [P4 · OneDrive's icon text in other languages](cards/P4-other-languages.md) | The exact-status path (Accessibility) classifies OneDrive's text in the languages OneDrive ships, not just English | C2 | T2, T3 | later |

## What waits for what

Arrows mean the card at the arrow's tail must be committed to `main` first. Dashed boxes are your decisions, not cards.

```mermaid
flowchart LR
  ICON["App icon<br/>on hold · your call"]
  ENROL["Apple Developer Program<br/>$99 a year · your call"]
  TESTER["A named tester or<br/>maintainer per adapter"]
  XCODE["Xcode installed<br/>your call"]

  C1["C1 · Permission-free tracking ✓"]
  A1["A1 · Lid line ✓"]
  A2["A2 · Alerts ✓"]
  C2["C2 · SyncProvider protocol"]
  A3["A3 · Stuck files"]
  A4["A4 · Legend and age"]
  A7["A7 · OneDrive update check"]
  R1["R1 · Developer ID + notarized DMG"]
  R2["R2 · Sparkle updates"]

  P1["P1 · iCloud Drive"]
  C3["C3 · Any CloudStorage folder"]
  T1["T1 · velumctl"]
  A5["A5 · Sleep guard"]
  A6["A6 · Sync history"]
  S2["S2 · Diagnostics, redacted"]
  S1["S1 · Guided first run"]
  G2["G2 · Adapter guide"]
  R3["R3 · Homebrew tap"]
  G1["G1 · Public repo page"]
  G3["G3 · Launch"]
  P2["P2 · Dropbox, deep"]
  P3["P3 · Google Drive, deep"]

  T2["T2 · Shortcuts"]
  T3["T3 · Control + widget"]
  P4["P4 · Other languages"]

  C1 --> A1
  C1 --> A2
  C1 --> C2
  C2 --> A3
  C2 --> A4
  C2 --> A7
  ENROL --> R1
  R1 --> R2
  R1 -.->|real notifications| A2

  C2 --> P1
  C2 --> C3
  C2 --> T1
  C2 --> A5
  C2 --> A6
  C2 --> S2
  A1 --> A5
  A2 --> A5
  C3 --> S1
  P1 --> S1
  C3 --> G2
  P1 --> G2
  R2 --> R3
  ICON --> G1
  R2 --> G1
  S2 -->|issue templates ask for it| G1
  G1 --> G3
  R3 --> G3
  P1 -->|launch with iCloud| G3
  G2 -.-> G3
  C3 --> P2
  C3 --> P3
  TESTER --> P2
  TESTER --> P3

  T1 --> T2
  T1 --> T3
  R1 --> T2
  R1 --> T3
  XCODE --> T2
  XCODE --> T3
  C2 --> P4

  classDef done fill:#e6f4ea,stroke:#34a853
  classDef gate stroke-dasharray: 5 5
  class C1,A1,A2,C2,P1,P3 done
  class ICON,ENROL,TESTER,XCODE gate
```

| Wave | Cards | Why |
|---|---|---|
| 1 | C2, R1 | C2 touches nearly every Swift file, so no other code card runs beside it. R1 touches only the build and signing scripts and `Info.plist`, and starts once you have enrolled. |
| 2 | A3, A4, A7, R2 | Each owns a new file of its own plus marked lines in shared files. R2 needs R1's signed build. |
| 3 | P1, C3, T1, A5, A6, S2 | All need C2's protocol. P1 and C3 own different adapters; T1 and S2 add their own entry points; A5 and A6 own new files. |
| 4 | S1, G2, R3 | S1 and G2 need two real adapters and the generic tier to describe. R3 needs a Sparkle-era release to point at. |
| 5 | G1 | Waits for the icon, a release, and S2's redacted report, which the issue templates ask for. |
| 6 | G3 | Launch once: signed, on Homebrew, with iCloud Drive. |
| Gated | P2, P3 | Only with a named tester or maintainer (risk 3, adapters for clients you don't use). |
| Later | T2, T3, P4 | Only on real user requests (risk 5). T2 and T3 also need Xcode, which this Mac doesn't have: the Command Line Tools have no App Intents metadata processor and no extension templates. |

The longest chain is your enrolment → R1 → R2 → R3 → G3. The icon starts a second chain, icon → G1 → G3, which can finish no sooner than R2 does.

## Decisions the user makes

Collected here so they can be made in one sitting. Each card repeats its own.

| Card | Decision | Suggested |
|---|---|---|
| R1 | Join the Apple Developer Program ($99 a year) | Yes, before going public. Without it, three problems: macOS 15 and later make everyone click "Open Anyway"; Homebrew casks must pass Gatekeeper [V/S]; macOS refuses Velum's notifications (verified this week). The consultant's funding answer: free forever, with sponsors covering the fee |
| R1 | Universal build, or Apple silicon only | Universal, if the Command Line Tools can build the Intel half (R1 finds out); otherwise Apple silicon only, said in the README |
| R2 | Sparkle's update check is the first network connection Velum makes: check automatically, or ask on first run | Sparkle's own first-run question. The README's "makes no network connections" becomes "only to check for updates, if you allow it" |
| A2 | Once system notifications work: keep the "resolved" follow-up, or errors only (the consultant's default) | Keep as built: each problem, then one "resolved" note |
| A3 | How long before a file counts as stuck | 10 minutes, the same as the stuck alert |
| A5 | Warn only, or also hold off sleep briefly while uploads finish | Warn only; never hold up sleep or shutdown |
| A6 | How much history to keep | 30 days, on this Mac only |
| C3 | Show the generic tier's folders by default, or behind a switch | Shown, each labelled beta |
| G1 | The app icon | On hold, your call |
| G1 | When the repo goes public, and whether `docs/plans/` goes public with it | After R2's first release and the icon; keep the plans, they show where Velum is going |
| G1 | Sponsor links: GitHub Sponsors, Ko-fi, both, or none | GitHub Sponsors only |
| G3 | Where and when to post; you post | Once, after G1: r/macapps and Show HN, then replies in the OneDrive-icon threads |
| P2, P3 | Who tests Dropbox and Google Drive (you use neither) | Nobody yet: leave them gated |
| T2, T3 | Install Xcode | Only when someone asks for these |

## Rules every card follows

- Read this page, [the memo](strategy-memo.md), [the README](../../../README.md) and your card before writing code.
- **Ask the user where the work goes** (the main checkout on `main`, or a worktree) before you start. Ask again before committing, and again before pushing.
  - Commits use the repo's own noreply identity (`git config user.email` in this repo); never change it.
  - Don't open pull requests or make branches of your own.
- **Never assume OK.** Velum never says "Up to date", "safe" or green without evidence it can name.
  - Every status carries its source and its age.
  - When the evidence runs out, the answer is `.unknown` with a reason.
  - A false "synced" is the worst bug this app can have (risk 4).
- **Observe, don't replace.**
  - No network connections. R2's update check is the one exception, and only as you decide.
  - No credentials. Never write a sync client's files or settings.
  - The only things Velum does to a client are commands the user clicks (Restart, Quit).
- **The user's cloud folders are theirs.**
  - Writing a probe file into a synced folder needs the user's yes each time.
  - Delete probes afterwards, and only once the last edit has settled (about 75 s); OneDrive restores a file deleted mid-sync.
  - Test fixtures are synthetic. Never copy the user's real OneDrive databases or logs into the repo: they hold file names.
- **System and security settings are the user's:**
  - Accessibility and the other privacy permissions;
  - System Settings → Menu Bar;
  - MenuBarAgent's preferences.

  Cards may open the right pane; they never change it.
- **Looks:** new UI follows the panel:
  - macOS 27 Liquid Glass;
  - the shell taken from Crisp (a non-activating panel on `NSGlassEffectView`);
  - SF Symbols and the panel's existing row styles.

  Borrow from Crisp (MIT) freely, and record what you took in `THIRD_PARTY_NOTICES.md`.
- **Build:** `./build.sh` uses the Command Line Tools only, so there is no `@State` macro: use `State(initialValue:)`. `./build.sh --install` replaces the running app: ask first.
- **Tests:** `swift test`; Swift Testing works with the Command Line Tools on this Mac.
  - C2 creates `Tests/VelumTests`, and each later card adds its own test files there.
  - Live checks use `Velum --dump`, which prints what the panel would show.
- **Diagnostics:** `log show` returns nothing from an agent session on this Mac. Write what you need into Velum's own defaults or into `--dump`.
- **Codex in the background:** `codex exec … < /dev/null`, or it hangs waiting for input.
- When you finish, fill in the **Hand-off** at the bottom of your card (what you built, what you left out, anything a later card must know) and commit it with your work.

## Who owns which files

| Card | Owns |
|---|---|
| C2 | New `Sources/Velum/Providers/` (`SyncProvider.swift`, `OneDrive/`); what moves there out of `Model.swift`, `OneDriveFiles.swift` and `LiveStatus.swift`; the test target in `Package.swift`; `Tests/VelumTests/` |
| A3 | A listing method on `UploadTracker`, `StuckFilesView.swift`, the stuck alert's text in `Notifier.swift` |
| A4 | `LegendView.swift`, the age text in `AccountRow`, the `.unknown` reasons in the OneDrive adapter |
| A7 | `Providers/OneDrive/Compatibility.swift`, the README's tested-version line |
| R1 | `build.sh`, `Scripts/` (signing, `release.sh`, `build-dmg.sh`), `Resources/Velum.entitlements`, `Info.plist`'s version keys |
| R2 | The Sparkle dependency, `Updater.swift`, `docs/appcast.xml`, `RELEASING.md`, the ••• menu's Check for Updates… |
| P1 | `Providers/iCloud/` |
| C3 | `Providers/Generic/` and the root discovery |
| T1 | `Sources/velumctl/`, its product in `Package.swift`, its copy step in `build.sh` |
| A5 | `SleepGuard.swift` |
| A6 | `History.swift`, `SparklineView.swift` |
| S2 | `Diagnostics.swift` (export and redaction), the ••• menu's Export Diagnostics…, `--redact` in `Entry.swift` |
| S1 | `FirstRunView.swift` and its first-launch flag |
| G2 | `docs/adapters.md` |
| R3 | The tap, a separate repository (`nafatyuk/homebrew-tap`) |
| G1 | `README.md`, images under `docs/`, `.github/ISSUE_TEMPLATE/`, `.github/FUNDING.yml` |
| G3 | Drafts outside the repo, in `~/Local Documents/Velum/launch/` |
| P2, P3 | `Providers/Dropbox/`, `Providers/GoogleDrive/` |
| P4 | The OneDrive adapter's text classification and its tests |
| T2, T3 | The Xcode or XcodeGen project and the extension targets |

**Shared files, edited only on your own lines with exact-string edits:**
- `PanelView.swift`: one line per new section, one line per new ••• menu item;
- `AppDelegate.swift`: one line per thing started at launch;
- `Package.swift`;
- `build.sh`;
- the README's "What you get" list.

## Left out on purpose

- **Becoming a sync client or mounter.** SyncTray, ExpanDrive, CloudMounter and Mountain Duck replace the vendor's client; Velum observes it.
- **A menu bar manager.** Ice, Bartender, Thaw and macOS's own Allow in the Menu Bar hide icons. Velum merges status; it doesn't manage other apps' icons.
- **Per-provider settings front ends, and anything networked or holding credentials.**
- **The Mac App Store.** Its sandbox stops Velum reading other apps' files and processes [S].
- **Setapp** [S, low–medium confidence].
- **A Focus filter.** There are reports of `perform()` never being called on macOS 26.5 [S, low]. Revisit if Apple fixes it.
- **A new name.** Velum stays: it fits more than one cloud.
- **Risk 2, Apple or Microsoft fixing the icons themselves.** It gets no card of its own. The multi-provider and assurance cards are the answer, because they outlive the icon problem.
