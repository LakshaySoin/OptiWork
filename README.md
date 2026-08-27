# Menu-Bar Activity Tracker — Beta

A macOS menu-bar app that tracks your **focused** time per activity (coding, reading, watching, chatting…), excluding idle — unlike Screen Time, which only reports foreground *apps*.

**Status: Phase 1 vertical slice is live.** The pure core, the SQLite persistence seam, the OS adapters, and the menu-bar UI are all built; the app runs as a real `.app` bundle. Product/architecture docs: **`PRD.md`** and **`docs/adr/`** (9 decision records).

## Layout

```
Package.swift                        SwiftPM manifest (macOS 13+)
Sources/FocusTrackerCore/            The pure core (no OS/UI deps):
  Types.swift      Category, ActivityModel, ActivityState, Segment, CurrentActivity, Observation
  Classify.swift   Classification seam + curated DefaultRules (ADR-0005)
  Tracker.swift    Pull-based aggregator: observe / breakdown / segments / currentActivity (ADR-0002)
  Store.swift      Persistence seam + InMemoryStore fake (ADR-0006)
Sources/FocusTrackerStore/
  SQLiteStore.swift   Production Store adapter: raw observation log + closed segments (ADR-0006)
Sources/FocusTrackerAdapter/
  SystemSources.swift    Frontmost app (NSWorkspace), idle readout (CGEventSource), blackout edges
  WindowTitleReader.swift AXUIElement window title + Accessibility trust checks (ADR-0004)
  TrackController.swift   Sampling loop → core observations → durable log; Snapshot publisher
Sources/ProductivityManager/
  main.swift / AppDelegate.swift   Accessory app: status-item dot + popover (ADR-0007)
  Presentation.swift / Views.swift Today | Week | Settings surfaces
Tests/FocusTrackerCoreTests/         Core behavior suite (XCTest)
Tests/FocusTrackerStoreTests/        SQLite round-trip / recompute suite (XCTest)
Scripts/build_app.sh                 Release build → codesigned build/ProductivityManager.app
Scripts/smoke.swift                  Legacy standalone smoke driver (superseded by `swift test`)
```

## Running

```bash
swift test                      # full suite (core + store): all green
./Scripts/build_app.sh          # release .app at build/ProductivityManager.app
open build/ProductivityManager.app
```

Run from the **`.app` bundle**, not a bare binary — macOS ties the Accessibility grant to the bundle identity, so a proper bundle keeps consent across launches.

## Behavior implemented

- **Focused-time accounting (ADR-0003)**: input-active categories tolerate no-input gaps up to their threshold (reading code ≠ idle); watching counts by presence only; idle past threshold accrues to nothing.
- **Blackout**: screen lock (`com.apple.screenIsLocked`) and system sleep emit `.sleep`/`.wake`; those stretches never count as work.
- **Window-title splitting (ADR-0004)**: browser tabs map to different categories when Accessibility is granted; degrades silently to app-level otherwise (onboarding explains why before prompting).
- **Durability (ADR-0006)**: every raw observation is appended to SQLite as it happens; relaunch replays ≥14 days of history so restarts lose nothing. Completed days freeze into closed segments.
- **Determinism (ADR-0002)**: one source of truth — menu bar, Today, Week, and (future) overrides/export all read from core queries over the same log.

## Beta notes

- Data lives at `~/Library/Application Support/ProductivityManager/tracker.sqlite`.
- Not yet built (Phase 1.1/1.2): session overrides + learned rules, CSV export, week-over-week polish beyond the delta table.
