# R3 · A Homebrew tap

**Bucket** R Release · **Part two** · **Status: planned** · **Waits for** R2 (the repo is already public) · **Runs alongside** S1, G2 · **Feeds** G3

## Brief

The consultant's plan for Homebrew: a personal tap first, then the main cask later, as Crisp did [V] ([memo](../strategy-memo.md) §5, item 3). Homebrew casks must pass Gatekeeper, so this follows R1 and R2.

Crisp's `RELEASING.md` (github.com/didriksg/Crisp) records what matters:
- **Release tags.** Homebrew's bot finds new versions from GitHub's latest release, and it skips prereleases.
- **`auto_updates true`** suits a Sparkle app: `brew upgrade` still upgrades a copy that hasn't updated itself.
- **The `binary` line** for a command-line tool (T1's `velumctl`) goes in only after a release that contains it.

A tap is a public GitHub repository, and the release it points at must be downloadable without signing in. Velum's repo has been public since November 12, so the tap works for others as soon as R1 and R2 have published a release. Publishing the tap is your go-ahead.

Read the [campaign rules](../README.md#rules-every-card-follows), [R1's](R1-developer-id-and-notarized-dmg.md#hand-off) and [R2's](R2-sparkle-updates.md#hand-off) hand-offs, and Crisp's "Homebrew" section.

**The idea:** a shelf in a shop people already visit. The product is the same; it's just where people look.

## Work

- **The tap repository** `nafatyuk/homebrew-tap`, with `Casks/velum.rb`:
  - `url` pointing at the release DMG;
  - `sha256`;
  - `auto_updates true`;
  - the minimum macOS version;
  - a `zap` stanza that removes Velum's preferences and `~/Library/Application Support/Velum`.
- **Per-release steps** in `RELEASING.md`: bump the tap's version and checksum.
- **The `binary` line** for `velumctl`, once a release ships it.
- **Later, not now:** submitting to the main Homebrew cask repository, once Velum has users. Its notability rules are [U]: check them then.

## Done when

- On this Mac, with the user's OK:
  1. `brew install --cask` from the local tap installs a working Velum.
  2. `brew uninstall --zap` removes it cleanly.
  3. The user's real copy is put back afterwards.
- `brew audit --cask --strict` passes (Homebrew is installed on this Mac).
- The tap repository exists only once the user says to create it.

## Ownership and limits

You own the tap repository and the Homebrew lines in `RELEASING.md`.

## Hand-off

_Not started._
