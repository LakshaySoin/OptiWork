import AppKit
import FocusTrackerAdapter
import FocusTrackerStore
import FocusTrackerCore

// Entry point: a faceless accessory app whose entire surface is one
// menu-bar item opening a single popover (ADR-0007).
// Top-level code runs on the main thread; assumeIsolated satisfies the
// MainActor-isolated AppDelegate under Swift 6 semantics.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()