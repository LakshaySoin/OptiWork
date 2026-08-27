import XCTest
@testable import FocusTrackerStore
import FocusTrackerCore

final class SQLiteStoreTests: XCTestCase {

    private var storePath: String!

    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory()
        storePath = (dir as NSString).appendingPathComponent("fx-test-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: storePath)
        try? FileManager.default.removeItem(atPath: storePath + "-wal")
        try? FileManager.default.removeItem(atPath: storePath + "-shm")
    }

    private func makeStore() throws -> SQLiteStore {
        try SQLiteStore(path: storePath)
    }

    func testSaveAndLoadSegments() throws {
        let store = try makeStore()
        let coding = Segment(category: .coding, state: .active, start: 0, end: 100)
        let watching = Segment(category: .watching, state: .active, start: 150, end: 400)
        try store.save(coding)
        try store.save(watching)

        let all = try store.segments(in: 0..<500)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].category, .coding)
        XCTAssertEqual(all[1].category, .watching)
        XCTAssertEqual(all[1].start, 150)
        XCTAssertEqual(all[1].end, 400)

        // Range clipping: only segments intersecting the range.
        let mid = try store.segments(in: 120..<200)
        XCTAssertEqual(mid.map(\.category), [.watching])
    }

    func testReplaceRewritesRangeAtomically() throws {
        let store = try makeStore()
        try store.save(Segment(category: .browsing, state: .active, start: 0, end: 60))
        try store.save(Segment(category: .watching, state: .active, start: 60, end: 120))

        // Override flow: reclassify the second stretch as chatting.
        try store.replace(in: 60..<120, with: [
            Segment(category: .chatting, state: .active, start: 60, end: 120),
        ])

        let all = try store.segments(in: 0..<500)
        XCTAssertEqual(all.map(\.category), [.browsing, .chatting])
    }

    func testObservationRoundTrip() throws {
        let store = try makeStore()
        try store.append(.foreground(app: "Xcode", windowTitle: nil, at: 5))
        try store.append(.input(at: 6))
        try store.append(.idleReadout(idleSeconds: 30, at: 40))
        try store.append(.sleep(at: 50))
        try store.append(.wake(at: 80))
        try store.append(.foreground(app: "Safari", windowTitle: "YouTube", at: 90))

        let loaded = try store.loadObservations(since: 0)
        XCTAssertEqual(loaded.count, 6)
        // Sorted by time.
        XCTAssertEqual(loaded.map(\.at), [5, 6, 40, 50, 80, 90])

        if case .foreground(let app, let title, _) = loaded[0] {
            XCTAssertEqual(app, "Xcode"); XCTAssertNil(title)
        } else { XCTFail("expected foreground") }
        if case .idleReadout(let idle, _) = loaded[2] {
            XCTAssertEqual(idle, 30)
        } else { XCTFail("expected idleReadout") }
        if case .foreground(let app, let title, _) = loaded[5] {
            XCTAssertEqual(app, "Safari"); XCTAssertEqual(title, "YouTube")
        } else { XCTFail("expected foreground") }

        // Since-filtering.
        let recent = try store.loadObservations(since: 60)
        XCTAssertEqual(recent.map(\.at), [80, 90])
    }

    func testDeleteObservationsBeforeCutoff() throws {
        let store = try makeStore()
        for t in [10.0, 20.0, 30.0] { try store.append(.input(at: t)) }
        try store.deleteObservations(before: 25)
        XCTAssertEqual(try store.observationCount(), 1)
        XCTAssertEqual(try store.loadObservations(since: 0).map(\.at), [30])
    }

    func testOverridePersistenceRoundTrip() throws {
        let store = try makeStore()
        try store.saveOverride(CategoryOverride(start: 100, end: 200, category: .reading))
        try store.saveOverride(CategoryOverride(start: 300, end: 400, category: .writing))

        var loaded = try store.loadOverrides()
        loaded.sort { $0.start < $1.start }
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].category, .reading)
        XCTAssertEqual(loaded[0].start, 100)
        XCTAssertEqual(loaded[1].category, .writing)

        // Re-asserting the same range replaces (primary key upsert).
        try store.saveOverride(CategoryOverride(start: 100, end: 200, category: .coding))
        try store.deleteOverride(start: 300, end: 400)
        loaded = try store.loadOverrides()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].category, .coding)

        // Survives reopen (restart durability).
        let reopened = try makeStore()
        XCTAssertEqual(try reopened.loadOverrides().first?.category, .coding)
    }

    func testReopenPersistsDataAcrossInstances() throws {
        do {
            let store = try makeStore()
            try store.append(.foreground(app: "Slack", windowTitle: "#eng", at: 100))
            try store.save(Segment(category: .chatting, state: .active, start: 100, end: 200))
        }
        // Fresh instance over the same file — the crash/restart path.
        let reopened = try makeStore()
        let observations = try reopened.loadObservations(since: 0)
        XCTAssertEqual(observations.count, 1)
        let segments = try reopened.segments(in: 0..<300)
        XCTAssertEqual(segments.map(\.category), [.chatting])
    }

    /// Property-flavored check mirroring the core's determinism guarantees:
    /// store → load reproduces exactly the timeline given to it.
    func testFullDayRoundTripMatchesBreakdown() throws {
        let events: [Observation] = [
            .foreground(app: "Xcode", windowTitle: nil, at: 0),
            .input(at: 1),
            .foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 50),
            .input(at: 60),
            .idleReadout(idleSeconds: 30, at: 120),
            .sleep(at: 200),
            .wake(at: 300),
        ]
        let store = try makeStore()
        for e in events { try store.append(e) }

        let live = Tracker(observations: events,
                           classify: DefaultRules.classifier(),
                           activityModel: DefaultRules.activityModel())
        let reloaded = Tracker(observations: try store.loadObservations(since: 0),
                               classify: DefaultRules.classifier(),
                               activityModel: DefaultRules.activityModel())
        XCTAssertEqual(live.breakdown(in: 0..<360), reloaded.breakdown(in: 0..<360))
    }
}
