<!-- Copied unchanged from the consultant's memo of November 10, 2026. Every card in this campaign traces to a line here. -->

# Velum strategy memo (Fable senior consultant, 2026-11-10)

Evidence marks: [V] verified by the consultant, [S] reported by a Haiku scout with sources, [U] unverified.

## 1. Thesis
Velum should become **the one sync-status light for a Mac**: a single native icon that says whether every
cloud folder is safe, whichever client syncs it, without replacing any client. Edge: "observe, don't
replace; merge, don't hide." No direct competitor found [S, partial]. Menu bar managers (Ice, Bartender,
Thaw, macOS "Allow in the Menu Bar") hide icons but show no status; SyncTray, ExpanDrive, CloudMounter,
Mountain Duck replace the vendor client.

Not: a sync client or mounter, a menu bar manager, a per-provider settings front end, or anything
networked or holding credentials.

Key fact: only OneDrive has the many-icons-per-account problem. Dropbox draws one icon [S], iCloud none
[V], Google Drive probably one for up to four accounts [U]. Elsewhere the value is "one light instead of N
apps' icons". OneDrive multi-account users stay the beachhead.

## 2. Roadmap

### Now (next few weeks)
| Item | Value | Feasibility | Effort | Risk |
|---|---|---|---|---|
| Permission-free tier as the product; Accessibility optional | Status survives OneDrive restarts | Built (Collector falls through File Provider flags, progress, diagnostics) [V] | S | Hourly lag for pause/offline; show status age |
| Notifications on state change (error, stalled > 10 min, back in sync) | A hidden icon can't catch your eye | UserNotifications needs a bundled, signed app; stable self-signature should hold [S] | S | Noise; default to errors only |
| Developer ID + notarized DMG + Sparkle | Otherwise nobody else installs it | Crisp does exactly this (RELEASING.md, appcast, fetch-sparkle.sh) [V] | M, $99/yr | Cost |
| Extract a `SyncProvider` protocol | Unblocks every later provider | TransferMonitor/UploadTracker already provider-agnostic except the `.fetch` filter [V] | M | Over-abstracting from one example |

Architecture: a generic File Provider tier (discover roots under `~/Library/CloudStorage/*`, feed the
existing trackers) plus a `SyncProvider` protocol (`discoverAccounts()`, optional `exactStatus()`,
`activity()`, `actions()`, `processIdentity`) with OneDrive as adapter one; keep per-row provenance.

### Next (1–3 months), provider order
1. **iCloud Drive** (M): per-file flags return real values in `~/Library/Mobile Documents/com~apple~CloudDocs`,
   and `/usr/bin/brctl status` runs unprivileged [V]. brctl output undocumented and noisy; parse defensively.
2. **Generic "any CloudStorage folder" tier, beta** (S once the protocol exists): Dropbox, Google Drive stream
   mode, Box, Proton, Nextcloud at basic fidelity [S]. Untested here (only OneDrive installed).
3. **Dropbox deep adapter** (M), only with a tester/contributor.
4. **Google Drive deep adapter** (M–L), community-driven; mirror mode has no flags [S].
Also: `velumctl status --json` CLI (S); `--dump` exists, Crisp ships `crispctl` [V].

### Later
- Control Center / menu bar Control and desktop widget (L): ControlWidget is macOS 26+ [S]; likely needs a
  sandboxed extension, an Xcode/XcodeGen project and an app-group snapshot [U]. Only after users exist.
- App Intents ("Is everything synced?") (M): spike first; may need an extension to appear in Shortcuts [S, low].
- Localised badge classification (M).
- Focus filter: skip (reports of `perform()` never called on macOS 26.5) [S, low].

## 3. Feature ideas, ranked by value over effort
1. **"Safe to close the lid?"** One line at the top: everything uploaded, or N files not yet in the cloud. (S)
2. **Stuck-file detector**: files pending past a threshold, with reveal in Finder (`oldestWaiting` exists). (S)
3. **Error notifications.** (S)
4. **Icon legend + "why is it unknown?" row.** Turns `.unknown` into trust. (S)
5. **`velumctl` / JSON output** for scripts, Raycast, backup jobs. (S)
6. **Pre-shutdown/sleep guard**: notify if sleep is requested with uploads pending. (M)
7. **Sync history sparkline per account**: makes silent multi-day stalls visible. (M)
8. **Guided onboarding** deep-linking to Menu Bar settings, detecting vendor icons. (S–M)
9. **Diagnostics export with automatic redaction.** (S)
10. **Controls and widget.** (L)
Items 1, 2, 6, 7 and 9 move Velum from icon tidier to sync assurance.

## 4. Positioning and naming
Keep "Velum" (fits multi-provider better). Taglines: now "Every OneDrive account, one cloud in your menu
bar."; after iCloud "Every cloud, one icon. Know your files are synced."; keep "merge, don't hide".
Lead public copy with the OneDrive multi-account pain (MacRumors, Microsoft Q&A, Parallels threads) [S].

## 5. Distribution and community
1. Pay the $99 and notarize (macOS 15+ needs "Open Anyway" otherwise; Homebrew casks must pass Gatekeeper) [V/S].
2. GitHub Releases DMG + Sparkle, copying Crisp's RELEASING.md flow [V].
3. Homebrew: personal tap first, main cask later (as Crisp did) [V].
4. Mac App Store: no (sandbox kills reading other apps' files and processes) [S].
5. Setapp: no [S, low-medium].
6. Public repo with screenshot, 20-second GIF, issue templates asking for redacted `--dump` output.
7. Launch once, after notarization and iCloud: r/macapps, Show HN, replies in OneDrive-icon threads. Comparable:
   Crisp ~2.4k stars in under four months with the same stack [S].
8. Funding: free forever, sponsors cover the Apple fee (Crisp's framing) [V].
9. Contributions: provider adapters as the unit; publish the protocol and an adapter guide.

## 6. Top five risks
1. OneDrive internals change → generic tier as floor, provenance, tested-version note, degrade to `.unknown`.
2. Apple/Microsoft fix it themselves → multi-provider and sync-assurance features outlive the icon problem.
3. Maintaining adapters for clients the owner doesn't use → generic tier only; deep adapters need a named maintainer.
4. Wrong-status trust failure (false "synced") → keep never-assume-OK, show status age, test generic tier per provider.
5. Scope creep past one person → hold the Now/Next line; gate Later items on real user requests.

**Start this week:** promote the permission-free tier (done in commit 0a85400), notifications, the
lid-close line, Developer ID enrolment.
