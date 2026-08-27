/// The deep module of the product: the pull-based tracking aggregator
/// (ADR-0002).
///
/// It appends raw `Observation`s to an in-memory log and answers range queries
/// (`breakdown`, `segments`) on demand, plus a derived live overlay
/// (`currentActivity`). It holds **no clock** — every observation is
/// timestamped by the caller — so identical ordered input always produces
/// identical output. That determinism is exactly what makes it testable purely
/// through its interface, and what keeps it Foundation-free so it builds with
/// only the Swift standard library.
///
/// Inside this small surface lives the complex logic: idle reconciliation,
/// input-active vs. presence-active policy, blackout handling, boundary
/// splitting, and day/across-time roll-up.
public struct Tracker {
    public private(set) var observations: [Observation]
    /// The classification seam (app/window → category).
    public let classify: Classifier
    /// The per-category activity model seam (inputActive vs. presenceActive).
    public let activityModel: ActivityModelProvider
    /// User corrections applied at render time (ADR-0005). Latest wins on
    /// identical ranges.
    public private(set) var overrides: [CategoryOverride]

    public init(
        observations: [Observation] = [],
        overrides: [CategoryOverride] = [],
        classify: @escaping Classifier,
        activityModel: @escaping ActivityModelProvider
    ) {
        self.observations = observations.sorted { $0.at < $1.at }
        self.overrides = overrides
        self.classify = classify
        self.activityModel = activityModel
    }

    /// Records a user correction. Re-asserting the same range replaces it
    /// (latest wins), which also serves as "undo" by re-picking the original
    /// category.
    public mutating func applyOverride(_ override: CategoryOverride) {
        overrides.removeAll { $0.start == override.start && $0.end == override.end }
        overrides.append(override)
    }

    /// Removes a correction entirely, restoring the automatic classification.
    public mutating func removeOverride(start: Instant, end: Instant) {
        overrides.removeAll { $0.start == start && $0.end == end }
    }

    /// Append a raw observation to the log (kept sorted by time).
    ///
    /// Arrival is overwhelmingly monotonic (live event streams), so the full
    /// sort only runs when an out-of-order append breaks the invariant —
    /// otherwise this is O(log n)-ish insertion. Identical result: the log
    /// is always sorted by `at`, preserving deterministic replay.
    public mutating func observe(_ event: Observation) {
        if let last = observations.last, event.at < last.at {
            observations.append(event)
            observations.sort { $0.at < $1.at }
        } else {
            observations.append(event)
        }
    }

    /// Per-category active time within a half-open range `[lowerBound, upperBound)`.
    /// `active` only — idle and blackout never accrue. Daily/weekly headline.
    public func breakdown(in range: Range<Instant>) -> [Category: TimeInterval] {
        var result: [Category: TimeInterval] = [:]
        for segment in segments(in: range) where segment.state == .active {
            result[segment.category, default: 0] += segment.duration
        }
        return result
    }

    /// Raw contiguous, non-overlapping activity segments within a range —
    /// clipped from the timeline and tail-extended to `upperBound`. Powers
    /// weekly trend, drill-down, override recompute, and export.
    public func segments(in range: Range<Instant>) -> [Segment] {
        let timeline = render()

        var clipped: [Segment] = []
        for segment in timeline where segment.end > range.lowerBound && segment.start < range.upperBound {
            let start = max(segment.start, range.lowerBound)
            let end = min(segment.end, range.upperBound)
            if end > start {
                clipped.append(Segment(category: segment.category, state: segment.state, start: start, end: end))
            }
        }

        // Tail: the query runs past the last committed observation. Carry the
        // ongoing state forward (e.g. still watching past the last event, or a
        // single foreground event with no later observations). Handles expiry,
        // presence, and blackout via the same activity model.
        if let last = observations.last, last.at < range.upperBound {
            let start = max(last.at, range.lowerBound)
            if range.upperBound > start {
                let tail = tailSegments(from: start, to: range.upperBound)
                if var previous = clipped.last, !tail.isEmpty, tail[0].category == previous.category, tail[0].state == previous.state, tail[0].start == previous.end {
                    previous.end = tail[0].end
                    clipped[clipped.count - 1] = previous
                    clipped.append(contentsOf: tail.dropFirst())
                } else {
                    clipped.append(contentsOf: tail)
                }
            }
        }
        return clipped
    }

    /// The derived live overlay for the menu-bar readout: current activity and
    /// how long it has been running. `nil` if there is no observation on or
    /// before `now`.
    public func currentActivity(at now: Instant) -> CurrentActivity? {
        guard let first = observations.first?.at, now >= first else { return nil }
        let timeline = render()
        if let segment = timeline.last(where: { $0.start <= now && now < $0.end }) {
            return CurrentActivity(category: segment.category, state: segment.state, since: segment.start)
        }
        // Live tail (post last event): replay state and evaluate at `now`.
        guard let last = observations.last else { return nil }
        let running = replay()
        let category = running.category ?? .untracked
        let since = max(last.at, first)
        if running.blackout {
            return CurrentActivity(category: .untracked, state: .blackout, since: since)
        }
        switch activityModel(category) {
        case .presenceActive:
            return CurrentActivity(category: category, state: .active, since: since)
        case .inputActive(let threshold):
            guard let lastInput = running.lastInput else {
                return CurrentActivity(category: category, state: .idle, since: since)
            }
            let activeTo = lastInput + threshold
            let state: ActivityState = now <= activeTo ? .active : .idle
            return CurrentActivity(category: category, state: state, since: since)
        }
    }

    // MARK: - Timeline reconstruction

    /// Recomputes the final running state (category, last-input witness,
    /// blackout flag) by replaying all observations without emitting segments.
    private func replay() -> (category: Category?, lastInput: Instant?, blackout: Bool) {
        var category: Category?
        var lastInput: Instant?
        var blackout = false
        for event in observations {
            switch event {
            case .foreground(let app, let title, _):
                category = classify(app, title)
            case .input:
                lastInput = lastInput.map { Swift.max($0, event.at) } ?? event.at
            case .idleReadout(let idleSeconds, let at):
                let revealed = at - idleSeconds
                lastInput = lastInput.map { Swift.min($0, revealed) } ?? revealed
            case .sleep:
                blackout = true
            case .wake:
                blackout = false
            }
        }
        return (category, lastInput, blackout)
    }

    /// Segments representing the ongoing state from `start` (the last committed
    /// observation time) to `end`, applying the activity model and expiry.
    private func tailSegments(from start: Instant, to end: Instant) -> [Segment] {
        let running = replay()
        let category = running.category ?? .untracked
        if running.blackout {
            return [Segment(category: .untracked, state: .blackout, start: start, end: end)]
        }
        switch activityModel(category) {
        case .presenceActive:
            return [Segment(category: category, state: .active, start: start, end: end)]
        case .inputActive(let threshold):
            guard let lastInput = running.lastInput else {
                return [Segment(category: category, state: .idle, start: start, end: end)]
            }
            let until = lastInput + threshold
            if start >= until {
                return [Segment(category: category, state: .idle, start: start, end: end)]
            } else if until >= end {
                return [Segment(category: category, state: .active, start: start, end: end)]
            } else {
                return [
                    Segment(category: category, state: .active, start: start, end: until),
                    Segment(category: category, state: .idle, start: until, end: end)
                ]
            }
        }
    }

    /// Reconstructs the contiguous timeline across the whole logged span.
    /// Contiguous from the first observation's time to the last observation's
    /// time, with no gaps (idle and blackout are explicit segments).
    private func render() -> [Segment] {
        guard let first = observations.first?.at, let last = observations.last?.at else {
            return []
        }
        guard first <= last else { return [] }

        var segments: [Segment] = []
        var pointer = first

        // Running state of the state machine.
        var foregroundCategory: Category?
        var lastInput: Instant?
        var blackout = false

        func emit(_ category: Category, _ state: ActivityState, from start: Instant, to end: Instant) {
            guard end > start else { return }
            if var open = segments.last, open.category == category, open.state == state, open.end == start {
                open.end = end
                segments[segments.count - 1] = open
            } else {
                segments.append(Segment(category: category, state: state, start: start, end: end))
            }
        }

        for event in observations {
            let t = event.at

            // 1) Flush the stretch [pointer, t) under the running state.
            if t > pointer {
                let category = foregroundCategory ?? .untracked
                if blackout {
                    emit(.untracked, .blackout, from: pointer, to: t)
                } else {
                    switch activityModel(category) {
                    case .presenceActive:
                        // Watching needs no input: always active while focused.
                        emit(category, .active, from: pointer, to: t)
                    case .inputActive(let threshold):
                        if let lastInput {
                            let until = lastInput + threshold
                            if pointer >= until {
                                emit(category, .idle, from: pointer, to: t)
                            } else if until >= t {
                                emit(category, .active, from: pointer, to: t)
                            } else {
                                emit(category, .active, from: pointer, to: until)
                                emit(category, .idle, from: until, to: t)
                            }
                        } else {
                            // No input witnessed yet in this stretch.
                            emit(category, .idle, from: pointer, to: t)
                        }
                    }
                }
            }

            // 2) Apply the event transition.
            switch event {
            case .foreground(let app, let title, _):
                foregroundCategory = classify(app, title)
            case .input:
                lastInput = lastInput.map { Swift.max($0, t) } ?? t
            case .idleReadout(let idleSeconds, let at):
                // A readout reveals the user last gave input at `at - idleSeconds`;
                // it can only push the last-input witness earlier.
                let revealed = at - idleSeconds
                lastInput = lastInput.map { Swift.min($0, revealed) } ?? revealed
            case .sleep:
                blackout = true
            case .wake:
                blackout = false
            }

            pointer = t
        }
        return applyOverrides(segments)
    }

    /// Overlays user corrections onto the rendered timeline: every *active*
    /// stretch intersecting an override range is split, with the covered
    /// slice recolored (ADR-0005). Idle/blackout pass through untouched.
    /// Adjacent pieces of the same category+state are re-merged so an override
    /// that agrees with the classifier leaves the timeline unchanged.
    private func applyOverrides(_ segments: [Segment]) -> [Segment] {
        guard !overrides.isEmpty else { return segments }
        var out: [Segment] = []
        out.reserveCapacity(segments.count)

        for segment in segments {
            guard segment.state == .active else {
                out.append(segment)
                continue
            }
            // Pieces of (start, end, category) progressively split by overrides.
            var pieces: [(Double, Double, Category)] = [(segment.start, segment.end, segment.category)]
            for override in overrides where override.end > segment.start && override.start < segment.end {
                var next: [(Double, Double, Category)] = []
                for (s, e, c) in pieces {
                    let os = max(override.start, s)
                    let oe = min(override.end, e)
                    if os >= oe {
                        next.append((s, e, c))
                        continue
                    }
                    if s < os { next.append((s, os, c)) }
                    next.append((os, oe, override.category))
                    if oe < e { next.append((oe, e, c)) }
                }
                pieces = next
            }
            for (s, e, c) in pieces {
                // Re-merge with the previous output piece when contiguous and
                // identical (e.g. override category equals original category).
                if var last = out.last, last.state == .active, last.category == c, last.end == s {
                    last.end = e
                    out[out.count - 1] = last
                } else {
                    out.append(Segment(category: c, state: .active, start: s, end: e))
                }
            }
        }
        return out
    }
}