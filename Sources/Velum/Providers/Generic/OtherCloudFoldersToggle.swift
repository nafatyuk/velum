import SwiftUI

/// ••• → Show Other Cloud Folders (card C3). On by default (decided overnight, November 13; the owner's to
/// reverse). Off, the generic tier's folders aren't discovered or watched at all: no rows, no alerts, and no
/// effect on the lid line, which then can say "safe" for the other services again (Fable's escape hatch: a
/// beta folder otherwise holds the lid at "can't vouch"). Shown only while the tier has folders, or while it
/// is switched off, so there is always a way back.
struct OtherCloudFoldersToggle: View {
    @ObservedObject var store: Store

    var body: some View {
        if store.snapshot.providers.contains(where: \.id.isBeta) || !GenericProvider.isShown {
            Toggle("Show Other Cloud Folders", isOn: Binding(
                get: { GenericProvider.isShown },
                set: { on in
                    GenericProvider.isShown = on
                    debugLog("action", "Show Other Cloud Folders \(on ? "on" : "off")")
                    store.refresh(force: true)
                }
            ))
        }
    }
}
