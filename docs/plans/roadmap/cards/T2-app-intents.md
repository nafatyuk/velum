# T2 · Ask Shortcuts "Is everything synced?"

**Bucket** T Tools and system surfaces · **Part three: later, only on real user requests** · **Status: later** · **Waits for** T1, R1, Xcode installed · **Runs alongside** T3, P4 · **Feeds** nothing

## Brief

With App Intents, Shortcuts, Spotlight and Siri could ask Velum "Is everything synced?" and use the answer: before a backup, before shutting down, or in a Focus automation. The consultant rates this medium effort, and says to run a spike first: it "may need an extension to appear in Shortcuts" [S, low confidence] ([memo](../strategy-memo.md) §2, "Later"). Risk 5 says to build Later items only when users ask.

**A fact for the spike, verified from Crisp's build script** (`scripts/appintents.sh`, github.com/didriksg/Crisp): Shortcuts finds an app's actions through `Contents/Resources/Metadata.appintents`, which Xcode's `appintentsmetadataprocessor` writes. The Command Line Tools on this Mac don't have that processor, and their compiler can't expand SwiftUI's macros while extracting the values. Crisp builds with plain `swiftc` but borrows both tools from Xcode. So this card needs Xcode installed, which is your call.

Read the [campaign rules](../README.md#rules-every-card-follows), T1's hand-off (the snapshot file) and Crisp's `appintents.sh`.

**The idea:** a doorbell intercom. Other apps press the button and get a yes or no, without walking into the panel.

## Work

- **The spike, first.** Can an in-app App Intent in an `LSUIElement` app built outside an Xcode project appear in Shortcuts, using Crisp's two-step route? Answer it with a throwaway intent before building anything.
- **The intents:**
  - "Is Everything Synced?" returns yes, no or unknown, plus the lid line's sentence;
  - "Files Not in the Cloud" returns a list;
  - "Open Velum".

  They read T1's snapshot, so they never need Velum's live state in their own process.
- **Build steps** adapted from Crisp's script, wired into `build.sh` and R1's `release.sh`, and skipped with a clear message when Xcode is missing.

## Done when

- The spike's answer is recorded in the hand-off.
- If it's yes: the three actions appear in Shortcuts on this Mac, a test shortcut gets the right answer with a probe pending and with nothing pending (probe with the user's yes, deleted afterwards), and a build without Xcode still works.

## Ownership and limits

You own the intents' source file and the App Intents build steps. Start only when a real user asks for this.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Install Xcode | Only when someone asks for this |

## Hand-off

_Not started._
