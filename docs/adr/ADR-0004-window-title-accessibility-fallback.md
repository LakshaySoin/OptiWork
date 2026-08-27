# ADR-0004 — Window-title tracking with app-level permission fallback

## Status

Accepted

## Context

Category accuracy requires knowing *which task* is frontmost — for a browser, "watching YouTube" vs. "reading an article". The OS exposes two levels of signal:

- **App-level** (`NSWorkspace`): which app is frontmost. No permission needed, but coarse — cannot split tasks within a single app.
- **Window-title-level** (`AXUIElement`): the active window title/domain. Needs the **Accessibility** permission, but enables precise categorization and the session-level override drill-down (Q10/ADR-0005).

Reads via `AXUIElement` trigger a one-time OS Accessibility prompt on first use.

## Decision

Track at **window-title level** when Accessibility is granted, and **silently degrade to app-level** if the user declines. Onboarding shows a short, honest explanation of *why* the permission is needed before the OS prompt. Functionality never *hard-requires* the permission.

## Consequences

- **Accuracy**: precise task attribution and window-title-based splitting (ADR-0005) are gated only on the user consenting — the default, not an option.
- **Resilience**: "no, thanks" degrades cleanly to app-level rather than disabling the app.
- Tradeoff: an extra permission-consent step at onboarding; must handle grant-later (re-check when the OS changes the setting).
- Tradeoff: window titles can be absent/opaque (e.g., a webpage with no title); classification must tolerate empty titles and fall back to the app rule.

## Supersedes/Related

Implements `FR-20..22` in the PRD. Enables the splitting behavior in ADR-0005.