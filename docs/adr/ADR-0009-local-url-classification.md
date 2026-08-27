# ADR-0009 — Local URL augmentation now; LLM classification only opt-in later

## Status

Accepted

## Context

Live beta testing showed browser misclassification when window titles are
opaque or unavailable ("watching YouTube" → browsing; "solving LeetCode" →
browsing). Two candidate remedies emerged:

1. **Fetch the active tab's URL** (local AppleScript: Chrome-family + Safari
   both expose it) and classify it with the existing needle engine — URLs are
   precise (`youtube.com/watch`, `leetcode.com/problems`) and deterministic.
2. **Send the URL (or title) to an LLM** for semantic classification.

The PRD's core honesty/privacy promise — reinforced in the Settings UI ("All
data is stored locally… nothing ever leaves this machine") and ADR-0006 —
rules out (2) as a default: shipping browsing history to a cloud LLM is a
product-category change, not a bug fix. It also adds cost, latency, and
failure modes to the hottest code path (a per-tick classification).

## Decision

- **Now**: locally fetch the active tab URL for supported browsers
  (Safari + Chromium family) via AppleScript and merge it with the AX title
  (`ForegroundSignal.combine`). The classifier's existing needles match
  either signal. First use triggers the standard per-browser Automation
  consent; declining degrades gracefully to title-only (ADR-0004 pattern).
- **Later (opt-in only)**: if rule coverage plateaus, add an *on-device*
  small-model classifier for unmatched URLs, or an explicit user-configured
  cloud endpoint behind a prominent privacy toggle. Never implicit.

## Consequences

- Precision gains without any network egress; classification stays pure and
  testable (URLs are just more strings at the `Classifier` seam).
- Automation consent adds one more prompt to onboarding; documented fallback
  keeps the app fully functional without it.
- Tradeoff: needle lists need tending (mitigated by Phase 1.1 learned rules
  and, eventually, opt-in models).

## Supersedes/Related

Refines ADR-0004 (title tracking) and ADR-0005 (classification seam).
Upholds the privacy constraint in ADR-0006 and the PRD's non-goals.
