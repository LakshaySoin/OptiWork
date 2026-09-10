import AppKit
import SwiftUI
import FocusTrackerCore
import FocusTrackerStore
import FocusTrackerAdapter

/// Owns the tracking loop, the status item, the popover, and onboarding.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: TrackController?
    let model = MenuModel()
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()
    private let hud = ClassifyHUD()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Persistence at ~/Library/Application Support/ProductivityManager/
        let store = try? Self.makeStore()
        if store == nil {
            NSLog("[ProductivityManager] falling back to session-only (no persistent store)")
        }

        let controller = TrackController(store: store)
        self.controller = controller

        controller.onUpdate = { [weak self] snapshot in
            MainActor.assumeIsolated {
                self?.model.apply(snapshot)
                self?.refreshDot(with: snapshot)
                if snapshot.isPaused {
                    self?.hud.hide()
                } else {
                    self?.hud.evaluate(snapshot)
                }
            }
        }

        hud.onClassify = { [weak self] app, start, end, category in
            guard let controller = self?.controller else { return }
            controller.applyOverride(start: start, end: end, category: category)
            // Also learn the mapping so this app is classified automatically
            // from now on — the question is asked once per app (ADR-0010).
            controller.learnRule(app: app, category: category)
        }

        setUpPopover()
        setUpStatusItem()
        controller.start()
        maybeShowOnboarding()
    }

    /// Raw data persists locally; nothing leaves the machine (ADR-0006).
    static func makeStore() throws -> SQLiteStore {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory,
                              in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("ProductivityManager", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteStore(path: dir.appendingPathComponent("tracker.sqlite").path)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.flushAndCommit()
        return .terminateNow
    }

    // MARK: Status item (the glanceable colored dot)

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = AppDelegate.dotImage(color: .systemGray.withAlphaComponent(0.4), hollow: false)
        item.button?.toolTip = "Productivity Manager"
        item.button?.action = #selector(togglePopover(_:))
        item.button?.target = self
        statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshDot(with snapshot: TrackController.Snapshot) {
        guard let button = statusItem?.button else { return }
        let now = snapshot.currentActivity

        // Paused: a hollow gray ring + explicit tooltip, distinct from every
        // live state so it's clear tracking is off.
        if snapshot.isPaused {
            button.image = AppDelegate.dotImage(color: .systemGray.withAlphaComponent(0.55), hollow: true)
            button.toolTip = "Productivity Manager — tracking paused"
            return
        }

        // ADR-0007 at-rest glance grammar — four distinguishable states:
        //   solid category color  → categorized activity, focused
        //   hollow ring           → active, but the app matches no rule
        //   dimmed (either shape) → idle / away
        //   black ring            → screen lock or sleep (blackout)
        var color = NSColor.systemGray.withAlphaComponent(0.4)
        var hollow = false
        switch now?.state {
        case .active:
            if now!.category == .untracked {
                hollow = true
                color = .labelColor.withAlphaComponent(0.75)
            } else {
                color = now!.category.nsColor
            }
        case .idle:
            let isUntracked = now!.category == .untracked
            hollow = isUntracked
            color = isUntracked
                ? .labelColor.withAlphaComponent(0.28)
                : now!.category.nsColor.withAlphaComponent(0.30)
        case .blackout:
            hollow = true
            color = .black
        default:
            break
        }
        button.image = AppDelegate.dotImage(color: color, hollow: hollow)

        if let now {
            let elapsed = max(0, snapshot.now - now.since)
            var suffix = ""
            if now.state == .idle { suffix += " (idle)" }
            if now.category == .untracked { suffix += " — no rule matched" }
            button.toolTip = "\(now.category.displayName) · \(Fmt.duration(elapsed))\(suffix)"
        } else {
            button.toolTip = "Productivity Manager"
        }
    }

    /// The glanceable 14pt readout — filled circle for recognized activity,
    /// ring outline when the state needs flagging.
    static func dotImage(color: NSColor, hollow: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inner = rect.insetBy(dx: 3.5, dy: 3.5)
            if hollow {
                color.setStroke()
                let path = NSBezierPath(ovalIn: inner.insetBy(dx: 0.9, dy: 0.9))
                path.lineWidth = 1.6
                path.stroke()
            } else {
                color.setFill()
                NSBezierPath(ovalIn: inner).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Popover (single surface: Today | Week | Settings)

    private func setUpPopover() {
        popover.contentSize = NSSize(width: 340, height: 360)
        popover.behavior = .transient
        popover.animates = true
        let root = RootView(model: model) { [weak self] in self?.controller }
        popover.contentViewController = NSHostingController(rootView: root)
    }

    // MARK: Onboarding — honest explanation before the OS prompt (ADR-0004)

    private func maybeShowOnboarding() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "onboarding.accessibility.completed") else {
            if !(controller?.accessibilityGranted ?? false) {
                openAccessibilitySettings()   // grant-later re-check path
            }
            return
        }
        defaults.set(true, forKey: "onboarding.accessibility.completed")

        guard controller?.accessibilityGranted == false else { return }

        let alert = NSAlert()
        alert.messageText = "See what you were actually doing"
        alert.informativeText = """
            Productivity Manager can read the title of your frontmost window — \
            that's how it tells “watching YouTube” from “reading an article” \
            inside the same browser.

            macOS asks for a one-time Accessibility permission for this. \
            Everything stays on this Mac; nothing is sent anywhere. Declining \
            is fine too — the app then tracks per-app only (a bit coarser).
            """
        alert.addButton(withTitle: "Enable Window Tracking")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            controller?.promptForAccessibility()
        }
        openAccessibilitySettings()
    }

    private func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}