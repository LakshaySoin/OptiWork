# ADR-0007 — Single popover (Today/Week) + glanceable menu-bar readout

## Status

Accepted

## Context

The product must feel like a native menu-bar utility: quick to consult, low friction. Two structural questions: (1) where daily breakdown + weekly analytics live, and (2) what the menu-bar item shows at rest.

Options for the surface: everything in one popover vs. a separate analytics window vs. the menu bar carrying a lot. Our "just check results" product goal favors keeping the whole product one click away. For the at-rest item, a plain icon hides everything (must click), a long text label adds noise, and a glanceable colored readout gives status without clicking.

## Decision

- **Surface**: a single **segmented popover** with **Today** and **Week** tabs, plus a **Preferences** panel opened from the same popover. No separate analytics window.
- **At-rest menu-bar item**: a **glanceable colored readout** — a small dot/segment tinted to the current category's color with subtle today info, quiet while idle. Clicking opens the Today popover.
- **Week tab content**: a **7-day stacked bar** (one bar per day, color-stacked by category) plus a **week-over-week per-category comparison**.
- **Today tab**: a live, per-category breakdown with drill-down to sessions (needed for overrides per ADR-0005).

## Consequences

- **Leverage**: UI is derived from the same core queries (`breakdown`/`segments`) — no drift between what's shown and the source of truth (ADR-0002).
- **Low friction**: whole product is one click away; status is glanceable without clicking.
- Tradeoff: a popover limits charts to compact sizes; the Weekly comparison is best kept simple (stacked bar + a small delta table) rather than large-chart.
- Tradeoff: today's live "right now" tail must be overlaid (ADR-0002); the UI just calls `currentActivity()`.

## Supersedes/Related

Implements `FR-12..16`. Depends on ADR-0002 (pull core) and ADR-0006 (store).