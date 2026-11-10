import AppKit
import ApplicationServices

/// The text OneDrive puts on its own menu bar icon, e.g. "OneDrive — Personal" / "Backed up and synced".
struct LiveItem: Equatable {
    let pid: pid_t
    let name: String      // "Personal", "Contoso"
    let status: String    // "Backed up and synced", "Syncing 3 files", "Paused", ...
}

/// Reads OneDrive's live status through the macOS accessibility API (needs Accessibility permission).
enum LiveStatus {
    static var isTrusted: Bool { !disabled && AXIsProcessTrusted() }

    /// Test switch (`--no-icon-text`): behave as if OneDrive's icons were hidden.
    nonisolated(unsafe) static var disabled = CommandLine.arguments.contains("--no-icon-text")

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func read() -> [LiveItem] {
        guard !disabled, AXIsProcessTrusted() else { return [] }
        var items: [LiveItem] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: oneDriveBundleID) where !app.isTerminated {
            for element in statusElements(pid: app.processIdentifier) {
                guard let title = string(element, kAXTitleAttribute) ?? string(element, kAXHelpAttribute) else { continue }
                let lines = title.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard let first = lines.first else { continue }
                items.append(LiveItem(
                    pid: app.processIdentifier,
                    name: accountName(fromTitleLine: first),
                    status: lines.dropFirst().joined(separator: " ")
                ))
            }
        }
        return items
    }

    /// Clicks OneDrive's own menu bar icon for one account, which opens OneDrive's panel.
    @discardableResult
    static func press(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(), let element = statusElements(pid: pid).first else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func accountName(fromTitleLine line: String) -> String {
        for prefix in ["OneDrive — ", "OneDrive – ", "OneDrive - "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }

    private static func statusElements(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success else {
            return []
        }
        return children as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
