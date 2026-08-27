import Foundation
import AppKit
import CoreGraphics
import FocusTrackerCore

/// Combines the two classification signals available for a browser into the
/// single `windowTitle` string the classifier consumes. Needles match either
/// the AX tab title or the raw URL — e.g. "Two Sum - LeetCode" and
/// "https://leetcode.com/problems/…" both contain "leetcode".
public enum ForegroundSignal {
    public static func combine(axTitle: String?, url: String?) -> String? {
        switch (axTitle, url) {
        case (nil, nil): return nil
        case (let t?, nil): return t
        case (nil, let u?): return u
        case (let t?, let u?): return "\(t) \(u)"
        }
    }
}

/// Reads the active tab's URL from the frontmost browser via local
/// AppleScript (no network, no third parties — the URL never leaves the
/// machine; PRD privacy guarantee). Unsupported apps return nil instantly.
///
/// The first query per browser triggers a one-time macOS Automation consent
/// prompt; declining degrades gracefully to title-only classification
/// (same pattern as ADR-0004's accessibility fallback).
public enum BrowserURLReader {

    /// AppleScript "scriptable as Chrome-family" browser names we support.
    private static let chromeFamilyKeywords = [
        "chrome", "chromium", "arc", "edge", "brave", "opera", "vivaldi",
    ]

    public static func supports(appName: String) -> Bool {
        let lower = appName.lowercased()
        return lower.contains("safari")
            || chromeFamilyKeywords.contains { lower.contains($0) }
    }

    /// The URL of the active tab, or nil when unavailable (unsupported app,
    /// no windows, automation declined, AppleScript error).
    public static func activeURL(forApp appName: String) -> String? {
        guard supports(appName: appName) else { return nil }
        let lower = appName.lowercased()
        let script: String
        if lower.contains("safari") {
            script = """
            tell application "Safari"
                if (count of documents) = 0 then return ""
                return URL of front document
            end tell
            """
        } else {
            // Chromium-family apps share the same scripting dictionary. Tell
            // them by their actual (localized) name so the right app is
            // targeted and non-running browsers are not launched blindly.
            script = """
            tell application "\(appName)"
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
            """
        }
        return execute(script: script)
    }

    private static func execute(script: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?
            .executeAndReturnError(&error)
        if let error {
            // Automation declined / app scripting unavailable — degrade quietly.
            NSLog("[ProductivityManager] URL read failed: \(error)")
            return nil
        }
        let value = result?.stringValue
        return (value?.isEmpty == false) ? value : nil
    }
}

/// A snapshot of what is frontmost right now, including the active-window
/// title when Accessibility allows it (ADR-0004).
public struct ForegroundSnapshot: Equatable, Sendable {
    public let appName: String
    public let pid: pid_t
    public let title: String?

    init(appName: String, pid: pid_t, title: String?) {
        self.appName = appName
        self.pid = pid
        self.title = title
    }

    static func none() -> ForegroundSnapshot? { nil }
}

@MainActor
public enum SystemSources {

    /// Who is frontmost right now — the primary signal feeding `.foreground`.
    public static func foreground() -> ForegroundSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? BundleInfo.guessExecutableName(of: app)
        let title = WindowTitleReader.focusedTitle(ofPID: app.processIdentifier)
        return ForegroundSnapshot(appName: name, pid: app.processIdentifier, title: title)
    }

    /// Seconds since any keyboard/mouse input system-wide. Reading this does
    /// **not** require Input Monitoring permission; the resulting readouts are
    /// fed to the core as `.idleReadout`, which reconciles the last-input
    /// witness itself (ADR-0002 / ADR-0003 without an extra prompt).
    public static func secondsSinceInput() -> Double {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    /// Subscribes to sleep/wake + screen lock/unlock — the blackout edges
    /// (`.sleep`/`.wake`). Returns tokens the caller keeps alive.
    public static func observeBlackout(onSleep: @escaping @MainActor () -> Void,
                                       onWake: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        var tokens: [NSObjectProtocol] = []
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { onSleep() } })
        tokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { onWake() } })

        let distro = DistributedNotificationCenter.default()
        tokens.append(distro.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { onSleep() } })
        tokens.append(distro.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { onWake() } })
        return tokens
    }
}

private enum BundleInfo {
    static func guessExecutableName(of app: NSRunningApplication) -> String {
        app.executableURL?.lastPathComponent ?? "Unknown"
    }
}