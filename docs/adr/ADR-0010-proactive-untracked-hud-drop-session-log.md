# ADR-0010 — Proactive untracked-classification HUD; drop the session log

## Status

Accepted — supersedes the session drill-down and retroactive disposition parts of ADR-0005 and the Today-tab session list in ADR-0007.

## Context

ADR-0005 exposed corrections via a session log in the Today tab: a list of timestamped segments the user could tap to relabel. Real use showed two problems:

1. **Retroactive classification doesn't work.** From timestamps alone, users cannot reliably reconstruct what they were actually doing in a session. Correction quality was poor and the interaction felt like homework.
2. **The log cluttered the product.** The Today tab filled with dozens of timestamp rows, burying the two things users actually open the app for: the live "right now" header and the day's category breakdown. The log's value (context for corrections) was outweighed by its cost (noise).

The valuable moment to ask "what is this?" is **when the app itself is uncertain** — i.e. when the current app/tab matches no rule and time is accruing to `untracked`. At that instant the user knows exactly what they are doing; later they won't.

## Decision

1. **Remove the session log and the retroactive correction sheet** from the popover entirely. The Today tab shows the live header and the per-category breakdown only. The override engine (apply/persist/recompute, ADR-0005/ADR-0006 mechanics) is retained — only its delivery surface changes.
2. **Add a proactive classify HUD** (`ClassifyHUD`): a borderless, non-activating floating panel in the **upper-right of the screen** that appears only while the current activity is active + `untracked`, asking "What are you doing in ⟨app⟩?" with the category buttons. Picking one applies an override spanning the current untracked stretch — the same persistence path as before, delivered at the moment of maximum user knowledge.
3. **Guardrails so the prompt helps rather than nags**: auto-dismiss after ~45 s; hide immediately once tracking becomes recognized/idle/blackout; per-app cooldown of 10 minutes; never shown for idle or blackout states.
4. **Deliberately a floating HUD, not a system notification**: `UNUserNotificationCenter` is unreliable for a SwiftPM CLI app (no bundle, permission prompt), and a HUD can host inline category buttons, which a banner cannot. `Snapshot` gained `foregroundApp` so the HUD can name the unrecognized app.

## Consequences

- **The popover is minimal and glance-first** (ADR-0007 intent restored): no scrolling list, no correction ceremony.
- **Correction quality should improve**: classification happens in-context, so labels reflect actual activity rather than reconstruction. To be validated with users (unvalidated assumption).
- **Tradeoff**: untracked time the user ignores stays untracked — there is no longer a log to sweep later. Accepted: the retroactive sweep produced bad labels anyway.
- **Tradeoff**: a floating panel appears over the user's screen. The cooldown + auto-dismiss + untracked-only trigger keep it rare; if users report annoyance, the next lever is a longer cooldown or a settings toggle.
- **Follow-up adopted**: when the user answers the HUD, the (app → category) mapping is **learned and persisted** (`app_rules` table via SQLiteStore, `TrackController.learnRule`); learned rules are consulted before curated defaults on every future observation, so each app is asked about at most once. Re-answering with a different category updates the rule. Listing/removing learned rules in Settings remains future work.

## Related

- Supersedes (in part): ADR-0005 (override delivery surface), ADR-0007 (Today-tab session list).
- Unchanged: ADR-0006 raw retention and override persistence; ADR-0002 derived views.
