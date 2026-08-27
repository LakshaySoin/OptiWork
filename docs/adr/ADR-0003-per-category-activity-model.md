# ADR-0003 — Per-category activity model (input-active vs presence-active; blackout)

## Status

Accepted

## Context

The core differentiator from Screen Time is *focused time*, but "no input" means different things for different activities:

- In a **code editor**, no input can mean "reading code" — still meaningful work, not idle.
- In a **video player**, there is **never** input while playing — it must count as active purely by being focused.
- A locked-screen or sleeping stretch must never be credited as "working" *or* as any task's idle/busy time.

A single global idle threshold (trusting OS system-idle) was rejected: it miscredits "staring at the editor" as idle and miscredits a playing video as idle.

## Decision

Each category declares an **activity model** that says *how* it becomes active and stops being active:

- **`inputActive(threshold)`** — counts as active while recent input exists, up to a per-category idle threshold. Used for coding, reading, writing, browsing. Editors/readers get a longer threshold (reading code is not idle).
- **`presenceActive`** — counts as active simply by being the frontmost window; no idle threshold. Used for watching/streaming/video.
- **Blackout** — screen lock and system sleep accrue to *nothing*: never "working", never a task's idle time.

## Consequences

- **Locality**: focused-time policy lives in one place (the core), keyed by category policy, rather than scattered across ad-hoc "is it interactive?" checks.
- **Leverage**: adding a user category that is presence-based (e.g., "music") is a one-line config, not new code.
- Tradeoff: per-category thresholds add a small preferences surface and more rule data per category (`category_defs.activityModel`, `idleThreshold`).
- Tradeoff: presence-active categories count all focused time with no idle carve-out by design (correct for video; the user accepts this).

## Supersedes/Related

Refines the "per-category idle thresholds" decision and the "screen-lock = blackout" assumption in the PRD. Implements `FR-5` and the activity models in `§6`.