import Foundation
import ApplicationServices
import FocusTrackerCore

/// Reads the focused window's title via the Accessibility API (ADR-0004).
/// Every call degrades gracefully: when Accessibility is not granted the
/// reader simply reports `nil` and tracking continues at app level.
public enum WindowTitleReader {

    /// Whether this process currently has Accessibility permission.
    /// Set `prompt` to trigger the one-time OS consent sheet.
    public static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The title of the focused window of the app at `pid`, or `nil` when it
    /// cannot be read (no permission, no windows, empty title).
    public static func focusedTitle(ofPID pid: pid_t) -> String? {
        guard isTrusted(prompt: false) else { return nil }
        let axApp = AXUIElementCreateApplication(pid)

        // Chromium/Electron apps (Chrome, Slack, Obsidian, VS Code…) don't
        // build their accessibility tree until an assistive client opts in.
        // Setting this flag asks them to expose window attributes. Harmless
        // no-op for native apps; takes effect by the next sample (~5s).
        let manualAccessibility = "AXManualAccessibility" as CFString
        AXUIElementSetAttributeValue(axApp, manualAccessibility, kCFBooleanTrue)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value else { return nil }

        // The AX value bridges to AXUIElement; force-cast guarded above by success.
        let axWindow = window as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title.isEmpty ? nil : title
    }

    /// The URL-like document path for a window title if it looks like a file,
    /// used later by richer classification. Kept here so UI/CLI tooling shares it.
    public static func debuggingDescription(ofPID pid: pid_t) -> String {
        guard let title = focusedTitle(ofPID: pid) else { return "(no title)" }
        return title
    }
}