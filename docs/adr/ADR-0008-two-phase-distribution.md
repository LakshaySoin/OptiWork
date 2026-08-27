# ADR-0008 — Two-phase distribution (clone-and-build → Developer-ID + Homebrew cask)

## Status

Accepted

## Context

The tool is **personal-first** but the author may later share it. Sharing options have different cost/audience tradeoffs:

- **Clone-and-build**: people clone the repo and Build/Run in Xcode. Free, no signing needed (they compile on their own Mac), but requires Xcode and only suits a technical audience.
- **Signed GitHub Release (.dmg/.zip)**: anyone can download and double-click. Requires a **Developer-ID–signed + notarized** build to avoid Gatekeeper "unidentified developer" warnings, which needs the **Apple Developer Program (~$99/yr)**.
- **Homebrew cask**: `brew install --cask` downloads the release and installs it. Free for end users; requires a signed `.dmg` on the release.
- **Mac App Store**: reach + auto-update, but sandboxing + review friction; not warranted for a measurement-focused menu-bar utility.

The app is **distribution-independent** (ADR-0001 native build; ADR-0006 local store), so the choice can defer without affecting how tracking works.

## Decision

Adopt a **two-phase** approach:

- **Phase 1 (now)**: develop via clone-and-build / Xcode dev loop; keep the repo clean and reproducible so "clone → Cmd-R" works for any technical contributor. No signing cost.
- **Phase 2 (when sharing with non-developers)**: publish a GitHub Release with a Developer-ID–signed, notarized `.dmg` and add a **Homebrew cask** (`brew install --cask`) as the smoothest one-command install. ~$99/yr is incurred only at this point and only on the publisher's side; install remains free for users.

## Consequences

- **Leverage**: spending nothing until there's an actual audience; the Homebrew path is the lowest-friction non-Store distribution and stays free for users.
- Tradeoff: non-technical users can't use the app during Phase 1 (they'd need Xcode) — acceptable until sharing is decided.
- Tradeoff: when Phase 2 engages, signing + notarization + a cask manifest are extra release-step work.
- Guarantee: tracking/persistence behave identically across dev build, signed dmg, and cask install.

## Supersedes/Related

Implements `Phase 2` in the PRD roadmap and `NFR-6` (distribution-independence). Applies the tech-stack decision in ADR-0001.