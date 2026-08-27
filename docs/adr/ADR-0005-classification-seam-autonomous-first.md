# ADR-0005 — Autonomous-first classification with an override seam

## Status

Accepted

## Context

"The app names your tasks itself" is the product's day-one value: the user should mostly just *check results*. But every user's app mix differs, and the classifier will occasionally make a clear, costly mistake. Two failure modes to avoid: a classifier so config-heavy that onboarding is a chore, and a classifier so rigid that a wrong label is uncorrectable.

## Decision

Two-part:

1. **Autonomous-first**: ship **curated default rules** mapping app / window-title → category (high recall, near-zero onboarding). Classification sits behind a **seam** (`Classify` dependency: `(app, windowTitle) → category`) so per-user mapping varies without touching the core.
2. **Override as safety net**, exposed in the Today view:
   - **Per-session override**: drill into a day → find a mislabeled segment → change its category; thanks to raw retention (ADR-0006) the app recomputes that day's totals on the spot.
   - **Learned rule**: if the same app/window is corrected to the same category repeatedly, the app proposes making it a **standing rule** in preferences — so the fix happens once and the app stays autonomous.

Window-title splitting is part of classification: hybrid apps (browsers) map tabs/domains to different categories by title, while dedicated single-purpose apps keep a single-rule mapping.

## Consequences

- **Locality**: rule logic and the "learn/apply override" behavior concentrate at the classify seam + store, not scattered across the UI.
- **Leverage**: overrides + learned rules + recompute all fall out of one seam and raw retention.
- Tradeoff: curated defaults carry ongoing maintenance as the app landscape shifts (mitigated by user overrides).
- Tradeoff: learned-rule bookkeeping (counting repetitions, proposing standing rules) is real feature work deferred to Phase 1.1.

## Supersedes/Related

Implements `FR-7..11` and the "autonomous-first / override-fallback" requirement in the PRD. Complements ADR-0004 (window-title) and ADR-0006 (SQLite raw retention that makes recompute possible).