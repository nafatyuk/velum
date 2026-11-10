# R2 · Updates through Sparkle

**Bucket** R Release · **Part one** · **Status: planned** · **Waits for** R1 · **Runs alongside** A3, A4, A7 · **Feeds** R3, G1

## Brief

Once others install Velum, they need updates. The consultant put "Developer ID + notarized DMG + Sparkle" in one "Now" row ([memo](../strategy-memo.md) §2, and §5, item 2): GitHub Releases plus Sparkle, copying Crisp's flow [V]. Crisp's pieces (github.com/didriksg/Crisp, MIT) are:
- `scripts/fetch-sparkle.sh`, which fetches a pinned Sparkle;
- `docs/appcast.xml`, served by GitHub Pages;
- `release.sh --publish`;
- a `RELEASING.md` checklist written from its own mistakes. Version 1.6.0 shipped an appcast item with a blank description, so everyone who updated saw an empty dialog.

Two facts shape this card:
- **Sparkle checks for updates over the network,** the first connection Velum would ever make. The README says Velum "makes no network connections", so this is your decision (below), and the README changes with it.
- **The repo is private until G1.** A private repo's Pages site and release files can't be fetched by an installed app. So the in-app update works for real only after G1. Until then, test with a local feed, as Crisp's `RELEASING.md` describes.

Read the [campaign rules](../README.md#rules-every-card-follows), [R1's hand-off](R1-developer-id-and-notarized-dmg.md#hand-off), and Crisp's `RELEASING.md` and `fetch-sparkle.sh`.

**The idea:** a forwarding address. Each copy of Velum knows where to look for its next version, and checks that the parcel carries your seal before opening it.

## Work

- **Sparkle 2, pinned.** Fetch it by version with a checksum, as Crisp does. Embed it in `Contents/Frameworks` with the right runpath, and sign its helpers inside-out in R1's signing step.
- **`Updater.swift`:** Sparkle's standard updater controller, plus "Check for Updates…" in the ••• menu.
- **EdDSA keys.** You run Sparkle's `generate_keys` yourself; it stores the private key in your login keychain. The card copies only the public key into `Info.plist` (`SUPublicEDKey`).
- **Release steps** added to R1's `release.sh`:
  1. Sign the DMG for Sparkle (`sign_update`).
  2. Write the appcast item, with the release notes as its Markdown description. Fail if the description is empty.
  3. Commit `docs/appcast.xml` with the version bump.
- **`RELEASING.md`,** adapted from Crisp's "Before the tag":
  1. Read the appcast that was written.
  2. Open the DMG and check its version.
  3. Check every step that is new to the pipeline.
  4. Run Velum's own checklist on this Mac: both accounts, the lid line, an alert.
- **README:** the network sentence changes, as you decide.

## Done when

- **The local feed test,** served from localhost:
  1. Version N is installed.
  2. The feed offers N+1.
  3. Check for Updates… finds it, checks its EdDSA signature, installs it and relaunches.
- Notification and Accessibility permissions survive the update (same Developer ID).
- A feed whose description is empty fails `release.sh`.
- The README and `RELEASING.md` are updated.

## Ownership and limits

You own:
- the Sparkle dependency and its fetch script;
- `Updater.swift`;
- `docs/appcast.xml`;
- `RELEASING.md`;
- the ••• menu's Check for Updates… (one line in `PanelView.swift`);
- the release steps added to R1's `release.sh`.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Check for updates automatically, or ask on first run | Sparkle's own first-run question; the README then says Velum connects to the internet only to check for updates, if you allow it |
| Where the appcast lives | GitHub Pages from `docs/`, as Crisp does, once the repo is public |

## Hand-off

_Not started._
