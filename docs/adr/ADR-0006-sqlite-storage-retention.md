# ADR-0006 — SQLite storage: raw segments + daily rollups

## Status

Accepted

## Context

The app stores every day's metrics locally and answers two query families: daily/weekly aggregates (fast reads) and point-in-time recomputation (after an override changes a segment's category). A storage choice must support both **bulk aggregation** and **raw retention / rewrite** efficiently, survive app restart without losing the open segment, and stay private (fully on-device). Candidates:

- **SQLite** — relational aggregation, transactional integrity, easy raw + rollup, millions of rows comfortably.
- **JSON/plist per-day files** — human-inspectable/portable but weaker for cross-week aggregation and crash-consistent writes.
- **Rollups only** — smallest and most private but can't recompute history after a category change (breaks ADR-0005's meaningful recompute), limiting weekly granularity.

## Decision

Use **SQLite**, storing **both raw observations/segments and pre-computed daily rollups**. Retention: no auto-prune for at least a year, with an optional privacy-based prune toggle. Provide **CSV export** of daily/category times. Persist the still-open segment before shutdown so restart loses nothing.

Store is a **real seam** (two adapters exist in practice: SQLite for production, an in-memory fake for the core/UI tests). The tracking core speaks an abstract Store interface; it never depends on SQLite directly.

## Consequences

- **Leverage**: weekly aggregation, day recompute after an override, export, and hypothetical `rules` re-applications are all cheap SQL queries over the same data.
- **Testability**: in-memory Store fake lets the deterministic core + UI tests run with no file I/O.
- Tradeoff: SQLite is a dependency and a schema to maintain; rollups must be invalidated/regenerated when a segment's category changes.
- Tradeoff: raw retention grows disk use (accepted; one year+ is modest for text-ish rows, and a prune toggle exists).

## Supersedes/Related

Implements `FR-17..19` and `NFR-4` in the PRD. Raw retention is what makes ADR-0005's override-recompute and ADR-0002's cheap range queries possible.