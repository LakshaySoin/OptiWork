# PRD — Menu-Bar Activity Tracker

**Status:** Approved (shared understanding reached through a design-tree interview)
**Date:** 2026-08-16
**Applies to:** a native macOS menu-bar utility that tracks *focused* time per activity.

---

## 1. One-line summary

A menu-bar app that tells you where your **real, focused time** actually goes each day — per task (coding, reading, watching videos, learning, chatting…) — excluding idle time, storing every day locally, and giving a daily breakdown plus a weekly trend.

## 2. Problem & why it differs from Screen Time

Screen Time tells you which **app** was in the foreground. It does **not** tell you:

- how much time you were **actually working** vs. staring at the screen,
- that a code editor being frontmost isn't the same as *coding* while away from the keyboard,
- that within a single app (a browser) you switched between **reading**, **watching**, and **chatting**.

This product answers those: **focused time per activity**, not foreground time per app.

## 3. Goals

- Automatically attribute focused time to meaningful activity **categories**, splitting a single app by window title where it matters.
- Exclude idle for interactive tools while still counting "reading the editor" (no input but focused).
- Track **presence-based** activities (watching a video) correctly — playback needs no input.
- Treat screen-lock/sleep as **blackout** (accrues to nothing).
- Provide a **live "right now"** menu-bar readout, a **Today** breakdown, and a **Week** trend.
- Store everything **locally**, keep **raw** data, allow **CSV export**, and let the user fix misclassifications (recomputing the past).
- Work **autonomously** on day one (near-zero setup) while offering overrides as a safety net.

## 4. Non-goals (explicitly out of scope)

- Cloud sync, accounts, or multi-device.
- Screen-Time API / Family Controls (not accessible to third parties and not needed).
- Blocking apps or enforcing limits — this is **measurement**, not control.
- Group collaboration or sharing of stats.
- Automated forecasting beyond week-over-week comparison.

## 5. Personas

| Persona | Need | Priority |
|---|---|---|
| The user (you) | Low-friction, glanceable, trustworthy time truth | Primary |
| A technical friend (clone-and-build) | Reproducible repo; builds in Xcode | Secondary |
| A non-technical friend (later) | One-command install via Homebrew cask | Future |

## 6. Key differentiators (behavioral rules)

1. **Input-active vs presence-active categories.**
   - *Input-active* (coding, reading, writing, browsing): time counts as active while recent input exists, up to a per-category idle threshold (editors/readers get a longer tolerance because reading code is not idle).
   - *Presence-active* (**watching/video**): counts as active simply by being the frontmost window — no idle threshold, because watching requires no input.
2. **Blackout**: screen lock and system sleep accrue to *nothing* — never "working", never "idle".
3. **Window-title splitting**: a browser's tabs map to different categories (YouTube → watching, article → reading, Gmail → chatting). Dedicated single-purpose apps map by rule (Xcode → coding).
4. **Autonomous-first, override as safety net**: the app names tasks itself from curated defaults; the user fixes only clear/costly mistakes, and repeated fixes become learned rules.

## 7. Functional requirements

### 7.1 Tracking

- FR-1 Observe the frontmost application and (when permitted) its active window title, timestamped.
- FR-2 Observe a system idle readout and input events, timestamped.
- FR-3 Determine the current activity as `(category, startedAt, state)` where state ∈ {active, idle, blackout}.
- FR-4 Break a single window into finer activity when its title/domain maps to a different category than the app default.
- FR-5 Apply per-category activity model: input-threshold for input-active, presence for video; blackout on lock/sleep.
- FR-6 Emit an immutable, contiguous, non-overlapping **segment** (`category, start, end, activeMs, pauses[]`) whenever a boundary is crossed.

### 7.2 The core interface (single source of truth)

- I-1 Accept an ordered stream of raw observations (`foreground`, `input`, `idle`, `sleep/wake`).
- I-2 Answer `breakdown(range)` → per-category active time in a range.
- I-3 Answer `segments(range)` → raw segments in a range (powers weekly + recompute + export).
- I-4 Expose a derived `currentActivity()` overlay for the live readout.
- I-5 Be deterministic and free of any internal clock (all time arrives in event data).

### 7.3 Classification

- FR-7 Ship curated default rules mapping app / window-title → category (high recall, near-zero onboarding).
- FR-8 Expose classification as a seam so per-user overrides can be added without touching the core.
- FR-9 Support per-session override: user changes a segment's category; the app recomputes affected day(s).
- FR-10 Learn a standing rule from repeated overrides of the same app/window → suggest it in preferences.
- FR-11 Allow user-defined categories (name + color) and edit of defaults.

### 7.4 UI

- FR-12 Single menu-bar popover with **Today** and **Week** tabs, plus a Preferences panel.
- FR-13 Menu-bar item shows a glanceable colored readout of the current category + subtle today info; quiet while idle.
- FR-14 **Today tab**: live, per-category breakdown for today with a drill-down to sessions (needed for overrides).
- FR-15 **Week tab**: 7-day stacked bar (one bar per day, color-stacked by category) + week-over-week comparison.
- FR-16 Preferences: categories (add/edit), idle thresholds, rules/overrides list, and export.

### 7.5 Storage

- FR-17 Persist **raw segments** and **daily rollups** in SQLite.
- FR-18 No auto-prune for at least a year; optional privacy-based prune toggle.
- FR-19 CSV export of daily/category times.

### 7.6 Permissions & onboarding

- FR-20 On first run, request **Accessibility** permission (one-time consent) for window-title reads.
- FR-21 If Accessibility is denied, silently degrade to **app-level** tracking (no window titles).
- FR-22 Show a short explanation of *why* the permission is needed before the OS prompt.

## 8. Non-functional requirements

- **NFR-1 Determinism**: the tracking core must reproduce identical output for identical ordered input regardless of wall-clock timing — this is the test surface.
- **NFR-2 Privacy**: all data stays on-device; no networking required; database is local.
- **NFR-3 Performance**: menu-bar resident; negligible CPU/memory; idle-aware (pause work when not active).
- **NFR-4 Resilience**: survive app restart (persist the open segment before shutdown); recover cleanly from a crash.
- **NFR-5 Portability**: the core has no UI/OS dependency so it could later be re-implemented in another language without touching the shell.
- **NFR-6 Distribution-independence**: tracking/persistence work identically for a dev Cmd-R build, a signed .dmg, or a cask install.

## 9. Architecture overview (deep-module sketch)

```
   OS signals (NSWorkspace, AXUIElement, idle readout, event monitoring)
        │  Adapter: translate raw OS callbacks → timestamped Observations
        ▼
┌─────────────────────────────────────────────┐
│ TRACKER CORE  (deep module, pure, no clock) │  interface: observe(), breakdown(range),
│  - idle reconciliation (idle-witness ↔ input)│           segments(range), currentActivity()
│  - input-active vs presence-active policy   │
│  - blackout handling                        │
│  - boundary splitting & segment emission    │
│  - day roll-up                              │
└────────────────┬────────────────────────────┘
                 │  (accepts a Classify dependency = the seam)
                 ▼           ▼
   SQLITE STORE     ANALYTICS/PRESENT (Today/Week views, live menu-bar readout)
   (raw + rollups)  (derived from the same core queries)
```

Key seams: **OS adapter** (outside the core), **Classify** (real seam — user mapping varies), **Store** (real seam — SQLite vs in-memory fake for tests).

## 10. Planned data model (high level)

- `observations` — raw, timestamped OS signals (retained for recompute/re-audit).
- `segments` — closed contiguous activity segments: `id, category, start, end, activeMs, app, windowTitle, pauses[]`.
- `daily_rollups` — per-(day,category) totals for fast daily/weekly reads.
- `rules` — default + user overrides / learned rules mapping app or (app,title) → category.
- `category_defs` — user-tunable categories (name, color, activity model, idle threshold).
- `settings` — idle thresholds, data-toggle, etc.

## 11. Roadmap / phases

**Phase 1 — Vertical slice (the first buildable version)**

- OS adapter: window-title when permitted (degrade to app-level), frontmost, idle, sleep/wake.
- Track: input-active + presence-active policy, blackout, boundary splitting.
- Core interface: `observe`/`breakdown`/`segments`/`currentActivity` with synthetic-event tests.
- SQLite persistence (raw segments + rollups).
- UI: menu-bar glance (colored readout), Today tab (live breakdown with session drill-down), basic Week stacked bar.
- Onboarding: one-time Accessibility consent w/ graceful fallback.
- Default classification rules + user categories (add/edit).

**Phase 1.1**

- Override flow: edit a session's category → recompute its day; learned-rule proposal on repetition.
- Week tab: week-over-week comparison.

**Phase 1.2**

- CSV export.
- Per-app drill-down within a category.
- Optional data prune toggle.

**Phase 2 — Distribution (when you choose to share)**

- GitHub Release with Developer-ID–signed, notarized `.dmg`.
- Homebrew cask (`brew install --cask`).
- Reproducible clone-and-build README.

## 12. Success criteria

- **Correctness**: for a synthetic event trace, the core's active/idle/blackout accounting matches a hand-computed reference (property test suite).
- **Granularity**: the app can separate reading vs. watching vs. chatting that all occur in the same browser session.
- **Honesty**: a locked-screen stretch never appears as "working" or as task time.
- **Autonomy**: a user can install, grant Accessibility, and get a trustworthy Today + Week view with no other setup.
- **Deliverable**: the vertical slice runs live on the menu bar and answers "what did I actually do today/this week" from real sessions.

## 13. Open/minor questions (non-blocking)

- Exact default category set + colors (proposed: Working, Coding, Reading, Learning, Watching, Chatting; others as user-added).
- Idle threshold defaults (proposed: interactive tools 2–5 min; browsing 1 min; video presence-based).
- Stacked-bar aesthetics and theme (light/dark, accent).
