# Contributing to Velum

Thank you for helping. Velum is small and kept that way on purpose, so a short note first saves everyone time.
It has one maintainer: replies can take a few days.

## What helps most

- **Bug reports.** Say what the panel showed, what was really true, and your macOS and sync app versions.
  `Velum --dump` output helps, but it prints account names, emails, your home path, and folder and file
  names: replace them all before you post it.
- **An adapter for a sync service you use every day.** Read [the adapter guide](docs/adapters.md) first.
  Every adapter needs a named maintainer who uses that service, so open an issue before you start.
- **Fixes** to anything that shows a status Velum can't back up.

Larger changes, or new features, start as an issue too: Velum deliberately leaves some things out (see
"Left out on purpose" in the [roadmap](docs/plans/roadmap/README.md#left-out-on-purpose)).

## Velum's promises

Every change keeps them:
- **Never assume OK.** Nothing says "Up to date", "safe" or green without evidence Velum can name. When the
  evidence runs out, the answer is "Can’t tell", with a reason.
- **Observe, don't replace.** Read-only: never write a sync app's files or settings. The only things Velum
  does to a sync app are the commands the user clicks (Start, Restart, Quit).
- **No network connections and no credentials.** The optional Google sign-in for storage is the one
  exception, off by default.
- **Nothing from a real account in the repository.** It is public. Tests use made-up data under
  `/Users/test`; never commit a real database, log, `--dump` or screenshot of your accounts.

## Building and testing

You need macOS 26 or later and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
./build.sh                                   # builds build/Velum.app, signed locally; doesn't install
Scripts/test.sh                              # runs the tests
.build/release/Velum --dump                  # prints what the panel would show
.build/release/Velum --render-panel out.png --sample healthy   # draws the panel from made-up data
```

`./build.sh --install` replaces the copy in `~/Applications` and relaunches it.

## Style

- Match the code around you. Comments say why, and name what was verified on a real Mac and when.
- UI text uses typographic apostrophes (`Can’t`), sentence case, and says what still holds after a problem
  ("Can’t read Google Drive 134’s queue · only uploads are tracked").
- The Command Line Tools ship SwiftUI's `@State` macro without its compiler plugin, so views hold the plain
  struct (`State(initialValue:)`) and use `.wrappedValue`.
- Code borrowed from another project is credited in `THIRD_PARTY_NOTICES.md`.

## Pull requests

- One topic per pull request, with tests for the behavior it changes.
- `Scripts/test.sh` passes.
- The README changes with any behavior a user would notice.
- Adapters also follow [the guide's checklist](docs/adapters.md#the-pull-request-checklist).

By contributing, you agree that your work is released under the [MIT License](LICENSE).
