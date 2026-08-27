# ADR-0000 — Architecture Decision Records

## Status

Accepted

## Context

This project makes several consequential architecture decisions (stack, tracking model, storage, seams, distribution). We record each as a standalone ADR so the *reasoning* and *consequences* are preserved for anyone who joins or revisits the design — including an AI coding agent.

We follow a lightweight MADR-style template: **Status · Context · Decision · Consequences**.

## Decision

Maintain a decision log at `docs/adr/`, one file per decision, numbered `ADR-NNNN`. Decisions state what was chosen, why (in deep-module vocabulary: module/interface/adapter/seam/depth), and the tradeoffs accepted. Revising a decision is a new ADR that supersedes the old one (reference `Supersedes`/`Superseded by`).

## Consequences

- Every significant decision is auditable and reversible in a controlled way.
- New contributors (human or agent) can reconstruct "why" without rediscovering it.
- Lightweight overhead: each ADR is short prose, not ceremony.

## Related ADRs

The decisions below refine and implement this one. They were produced as the agreed shared understanding for the menu-bar Activity Tracker (see `PRD.md`).