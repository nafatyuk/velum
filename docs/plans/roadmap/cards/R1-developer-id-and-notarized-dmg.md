# R1 · Developer ID and a notarized DMG

**Bucket** R Release · **Part one** · **Status: planned; waits on your decision to enrol** · **Waits for** your Apple Developer Program enrolment · **Runs alongside** C2 · **Feeds** R2, A2 (real notifications), T2, T3

## Brief

`Scripts/sign.sh` signs Velum with "Velum Local Signing", a self-signed identity kept in its own keychain file. That keeps the Accessibility permission across rebuilds on this Mac, and does nothing anywhere else:
- On other Macs, Gatekeeper refuses it; macOS 15 and later make people click "Open Anyway" in System Settings.
- Homebrew casks must pass Gatekeeper [V/S].
- macOS refuses notifications from it, without asking. This was verified this week; see [A2's hand-off](A2-problem-alerts.md#hand-off).

The consultant's verdict: "Otherwise nobody else installs it" ([memo](../strategy-memo.md) §2, "Now", row 3, and §5, items 1–2). Crisp does exactly this [V]. Its `docs/RELEASING.md` and `scripts/release.sh` / `build-dmg.sh` (github.com/didriksg/Crisp, MIT) are the model.

The tools are here: `notarytool`, `stapler`, `codesign`, `hdiutil` and `lipo` all ship with the Command Line Tools on this Mac, so this card needs no Xcode.

**Your part (Claude never does these):**
1. Enrol in the Apple Developer Program ($99 a year).
2. Create a Developer ID Application certificate and install it in your login keychain.
3. Store notarization credentials yourself with `xcrun notarytool store-credentials`, using an app-specific password.

Claude never types passwords, keys or Apple ID details.

Read the [campaign rules](../README.md#rules-every-card-follows), `build.sh`, `Scripts/sign.sh`, `Resources/Info.plist`, and Crisp's `RELEASING.md` ("Signing and notarization").

**The idea:** a passport instead of a library card. The library card (today's local signature) gets you in at home; the passport (Developer ID plus Apple's notarization stamp) gets you across every border.

## Work

- **`Scripts/sign.sh` picks the identity.**
  - It uses a "Developer ID Application" identity when one is present: set by `VELUM_SIGN_IDENTITY`, or found by `security find-identity -v -p codesigning`.
  - Otherwise it uses today's local identity, so contributors can still build.
  - Sign with the hardened runtime (`--options runtime`) and a timestamp.
  - Use an entitlements file only if it turns out to need one. Without a sandbox, reading other apps' files and using Accessibility should need no entitlement; confirm it.
- **`Scripts/release.sh vX.Y.Z`:**
  1. Build. Make a universal binary if the Command Line Tools can build the Intel half (per-architecture `swift build --triple …` plus `lipo`; find out). Otherwise build for Apple silicon only.
  2. Stamp the version keys in `Info.plist` from the tag.
  3. Sign inside-out.
  4. Zip the app, notarize it (`notarytool submit --wait`, using your stored profile), then staple it.
  5. Build the DMG (`Scripts/build-dmg.sh`: `hdiutil`, with an Applications shortcut), sign it, notarize it and staple it. Two submissions are unavoidable: Apple issues a ticket per file.
  6. The gate, last: `spctl -a -t open --context context:primary-signature` on the DMG and `spctl -a -vv` on the app. Under `set -e`, a rejection aborts the release. Crisp measured that an unsigned DMG with a stapled ticket passes `stapler validate` and is still rejected by Gatekeeper: trust `spctl`, not `stapler`.
- **Notifications.**
  - With the new signature, `Notifier.requestPermission()` should get macOS's real prompt.
  - Check the banner fallback still covers a "Don't Allow".
  - Ask the user whether to keep the "resolved" notes (A2's open decision).
- **Accessibility moves with the signature.** A new signature means macOS treats Velum as a new app. Anyone using exact status turns Velum's switch off and on again in Privacy & Security → Accessibility. Say so in the README and the hand-off.
- **Publishing a GitHub Release is the user's go-ahead.** The repo is private until G1, so its releases are private too.

## Done when

- `release.sh` produces a DMG that both `spctl` checks accept. Test it on a quarantined copy (`xattr -w com.apple.quarantine …` on a copy, never on the original).
- With the user's OK: the installed signed build shows macOS's notification prompt. After it is allowed, quitting OneDrive externally gives a real notification, and reopening it gives the "resolved" one.
- The README's Install section has both routes: the DMG, and building from source.

## Ownership and limits

You own:
- `build.sh`;
- `Scripts/` (signing, `release.sh`, `build-dmg.sh`);
- `Resources/Velum.entitlements`, if one is needed;
- `Info.plist`'s version keys.

Sparkle is R2's job.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Join the Apple Developer Program ($99 a year) | Yes, before going public. The consultant's framing: free forever, with sponsors covering the fee |
| Enrol as an individual or an organization | Individual: your name shows as the developer |
| Universal build, or Apple silicon only | Universal, if the Command Line Tools can build it; otherwise Apple silicon only, said in the README |

## Hand-off

_Not started._
