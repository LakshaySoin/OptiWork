/// A point in time, expressed in seconds. The core is deliberately
/// Foundation-free and has no clock: callers timestamp observations with plain
/// seconds, so the module stays deterministic, replayable, and buildable with
/// nothing beyond the Swift standard library.
public typealias Instant = Double
public typealias TimeInterval = Double

/// The taxonomy of activities this tracker attributes focused time to.
/// `untracked` is the fallback for anything the rules don't recognize and the
/// category we attribute to blackout (screen lock / sleep) stretches.
public enum Category: String, Hashable, Sendable {
    case working
    case coding
    case reading
    case learning
    case writing
    case browsing
    case watching
    case chatting
    case untracked

    public var displayName: String {
        switch self {
        case .working: return "Working"
        case .coding: return "Coding"
        case .reading: return "Reading"
        case .learning: return "Learning"
        case .writing: return "Writing"
        case .browsing: return "Browsing"
        case .watching: return "Watching"
        case .chatting: return "Chatting"
        case .untracked: return "Untracked"
        }
    }
}

/// *How* a category becomes (and stops being) active. The heart of the
/// "not like Screen Time" behavior (ADR-0003).
///
/// - `inputActive(threshold)`: time counts as active while recent input exists,
///   up to a per-category idle threshold. Coding/reading/writing use this — a
///   short no-input gap (reading code) still counts; a long one becomes idle.
/// - `presenceActive`: time counts as active purely by being the frontmost
///   window; no idle threshold. Watching/streaming use this (playback needs no
///   input and must never be carved into idle).
public enum ActivityModel: Hashable, Sendable {
    case inputActive(idleThreshold: TimeInterval)
    case presenceActive
}

/// The active/idle/blackout state of a stretch of time.
public enum ActivityState: Hashable, Sendable {
    case active
    case idle
    case blackout
}

/// A contiguous, non-overlapping slice of clock time.
public struct Segment: Hashable, Sendable {
    public var category: Category
    public var state: ActivityState
    public var start: Instant
    public var end: Instant

    public init(category: Category, state: ActivityState, start: Instant, end: Instant) {
        self.category = category
        self.state = state
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }
}

/// A user correction (ADR-0005 "override as safety net"): forces every
/// *active* stretch of the derived timeline intersecting `[start, end)` to
/// `category`. The raw observation log is never edited — overrides are an
/// overlay applied at render time, so removing one restores the original
/// classification. Idle and blackout states are never recolored: an override
/// changes *what* you were doing, not *whether* the time counted.
public struct CategoryOverride: Hashable, Sendable {
    public let start: Instant
    public let end: Instant
    public let category: Category

    public init(start: Instant, end: Instant, category: Category) {
        self.start = start
        self.end = end
        self.category = category
    }
}

/// What the menu bar shows "right now" (the derived live overlay, ADR-0002).
public struct CurrentActivity: Equatable, Sendable {
    public var category: Category
    public var state: ActivityState
    public var since: Instant

    public init(category: Category, state: ActivityState, since: Instant) {
        self.category = category
        self.state = state
        self.since = since
    }
}

/// The raw, timestamped OS signals the tracking core consumes (via its adapter).
/// Every event carries its own `at`; the core reads no clock, so it is
/// deterministic and replayable for tests (ADR-0002).
public enum Observation: Hashable, Sendable {
    /// The frontmost app/window changed.
    case foreground(app: String, windowTitle: String?, at: Instant)
    /// Any keyboard/mouse input at this instant (an "active" witness).
    case input(at: Instant)
    /// A system idle readout: "has been idle for `idleSeconds` as of `at`".
    case idleReadout(idleSeconds: TimeInterval, at: Instant)
    /// Screen locked / system sleeping. Everything until `wake` is blackout.
    case sleep(at: Instant)
    /// System waking / screen unlocked. Ends the current blackout.
    case wake(at: Instant)

    public var at: Instant {
        switch self {
        case .foreground(_, _, let at): return at
        case .input(let at): return at
        case .idleReadout(_, let at): return at
        case .sleep(let at): return at
        case .wake(let at): return at
        }
    }
}