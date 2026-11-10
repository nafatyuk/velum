# T3 · A Control and a widget

**Bucket** T Tools and system surfaces · **Part three: later, only on real user requests** · **Status: later** · **Waits for** T1, R1, Xcode installed · **Runs alongside** T2, P4 · **Feeds** nothing

## Brief

The one light could also live in Control Center, as a menu bar Control, and on the desktop as a widget. The consultant rates this large effort, "only after users exist" ([memo](../strategy-memo.md) §2, "Later"; §3, idea 10):
- `ControlWidget` is macOS 26 and later [S].
- It likely needs a sandboxed extension, an Xcode or XcodeGen project, and a shared app-group snapshot [U].

A sandboxed extension can't read OneDrive's files, so the app has to hand it the answer. T1's snapshot is the natural thing to share, written into an app-group container. An app group for a Developer ID app needs R1's team. Crisp generates its Xcode project with XcodeGen (`project.yml`) [V], which is a model for keeping the build scriptable.

Read the [campaign rules](../README.md#rules-every-card-follows), T1's and R1's hand-offs, and Crisp's `project.yml`.

**The idea:** a repeater light on a second wall. It shows the same light; it doesn't have its own sensors.

## Work

- **Spike first:**
  - Does a Control or widget extension need the whole app to move into an Xcode project?
  - Can XcodeGen keep the SwiftPM layout?
  - Does an app-group container work with a Developer ID app outside the App Store?
- **The snapshot in the app group,** written by the app beside T1's file.
- **The Control:** the one light and the lid line's verdict. Pressing it opens Velum's panel.
- **The widget,** small and medium sizes: the light, the verdict, and one line per account. It shows its own age, and becomes unknown when the snapshot is stale.

## Done when

- The spike's answers are recorded in the hand-off.
- If it goes ahead: the Control and widget show the right state on this Mac through a probe's life (with the user's yes, deleted afterwards), and show unknown when Velum isn't running.

## Ownership and limits

You own the project file and the extension targets. Start only when real users ask for this.

## Decisions for the user

| Decision | Suggested |
|---|---|
| Install Xcode and move to a generated Xcode project | Only when someone asks for this |

## Hand-off

_Not started._
