# ADR-0001 — Native Swift shell + pure Swift core

## Status

Accepted

## Context

The product is a macOS menu-bar utility whose entire value is **OS integration** (frontmost app, active-window title, input/idle signals). We evaluated the stack options that drive everything downstream:

- **Native Swift (AppKit/SwiftUI)** — first-class access to `NSWorkspace`, `AXUIElement`, event monitoring and idle readouts; lightweight resident footprint; native permission handling; matches comparable menu-bar utilities (Bartender, PopClip, Stats, Amphetamine).
- **Electron/Tauri + native helper** — fast iteration / web tech, but heavier, and the OS plumbing still ends up native behind a bridge.
- **Rust/Go core + native shell** — strong engine, but you hand-maintain FFI to AppKit/accessibility/CoreGraphics and still need a native UI shell.

Xcode is required for a native app in practice: building a proper `.app` bundle, code-signing, and the `Info.plist` usage-permission strings / entitlements that drive the Accessibility/input-monitoring prompts.

## Decision

Build the app in **native Swift**: AppKit/SwiftUI for the menu-bar shell and UI, with Xcode as the dev environment. Keep the **tracking core as a pure, deterministic Swift module** with no UI/OS dependency, so the core is unit-testable and could later be re-expressed in another language without touching the shell.

## Consequences

- **Leverage**: the hardest problems (permissions, window reads, idle signals) are first-class native APIs.
- **Locality**: OS plumbing concentrates in a thin adapter; the logic concentrates in the pure core.
- Tradeoff: Swift is slower to develop than web-tech for UI, but this app's UI is tiny (a popover + preferences), and the OS work dominates complexity — where native wins.
- Tradeoff: Xcode is a hard dependency for the dev loop (already the case on macOS).

## Supersedes/Related

Refines ADR-0000. Not a superseding of a prior technical stack — this is the first stack decision.