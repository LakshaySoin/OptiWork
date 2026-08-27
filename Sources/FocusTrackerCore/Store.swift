/// The persistence seam (ADR-0006). The `Tracker` and UI depend on this small
/// interface, not on SQLite directly — production uses a SQLite adapter; tests
/// and the menu-bar live view can use the in-memory adapter below.
public protocol Store {
    /// Persist one closed/committed segment.
    func save(_ segment: Segment) throws
    /// Load segments whose span intersects `range`.
    func segments(in range: Range<Instant>) throws -> [Segment]
    /// Delete and rewrite the affected interval (used by the override-recompute
    /// flow: change a segment's category, then recompute the day).
    func replace(in range: Range<Instant>, with segments: [Segment]) throws
}

/// In-memory adapter of `Store` — the deterministic fake used by the core
/// tests (two adapters ⇒ a real seam, per ADR-0006).
public final class InMemoryStore: Store {
    public private(set) var segments: [Segment] = []

    public init() {}

    public func save(_ segment: Segment) throws {
        segments.append(segment)
        segments.sort { $0.start < $1.start }
    }

    public func segments(in range: Range<Instant>) throws -> [Segment] {
        segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
    }

    public func replace(in range: Range<Instant>, with newSegments: [Segment]) throws {
        segments.removeAll { $0.end > range.lowerBound && $0.start < range.upperBound }
        segments.append(contentsOf: newSegments)
        segments.sort { $0.start < $1.start }
    }
}