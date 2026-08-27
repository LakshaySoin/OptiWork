# ADR-0002 — Pull-based aggregator as the tracking core

## Status

Accepted

## Context

The heart of the system decides the *shape of the seam* callers and tests cross. Three candidate designs all hide similar complex logic (idle reconciliation, active-vs-presence, boundary splitting) behind a small surface:

- **A. Event-fold reducer** — pure fold over the event stream producing `Session` records; best property-testing story (batch-invariance).
- **B. Pull-based aggregator** — append raw observations to an immutable log, answer `breakdown(range)`/`segments(range)` on demand.
- **C. Activity-interval model** — stateful live interval that closes/emits on boundaries.

Our two consumers — the menu bar's live "today so far" and weekly analytics — are both effectively **range queries**, and correctness (active/idle honesty) is better proven on a deterministic, replayable log than on mutable incremental counters.

## Decision

Adopt **B — the pull-based aggregator** as the tracking core. The module:

- accepts an **ordered stream of raw observations** (`foreground`, `input`, `idle`, `sleep/wake`) via `observe(...)`;
- answers `breakdown(range)` (per-category active time) and `segments(range)` (raw contiguous activity segments) on demand;
- exposes a derived `currentActivity()` overlay for the live readout;
- holds **no internal clock** — all time arrives in event data, making the module deterministic and fully testable by replaying synthetic traces.

## Consequences

- **Leverage**: one query shape (`breakdown`/`segments`) serves live-today, weekly trend, recompute-after-override, and export — no drifting duplicate counters; the display is always derived from the same source of truth.
- **Testability**: tests feed ordered synthetic events and assert on returned queries; no clock mocking and no OS mocking.
- Tradeoff: the two in-flight "current session tail" must be folded into range answers (the live overlay), which slight extra machinery but stays behind the interface.
- Tradeoff: pull-based means disaggregating is cheap; we accept that raw observation retention costs space (mitigated by SQLite, ADR-0006).

## Supersedes/Related

Converged from the three designs produced during the DESIGN-IT-TWICE exercise. Implements `I-1..I-5` and `FR-3`/`FR-6` in `PRD.md`.