import XCTest
@testable import FocusTrackerCore

/// Port of the core behaviors, Foundation-free (times are plain seconds).
/// Run via `swift test` once a Swift toolchain with working SwiftPM is
/// available; until then use `Scripts/smoke.swift` + `swiftc`.
final class TrackerTests: XCTestCase {

    private func tracker(_ observations: [Observation] = []) -> Tracker {
        Tracker(observations: observations, classify: DefaultRules.classifier(), activityModel: DefaultRules.activityModel())
    }

    private func assertNear(
        _ actual: TimeInterval, _ expected: TimeInterval,
        accuracy: TimeInterval = 1.5,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, accuracy: accuracy, message, file: file, line: line)
    }

    func testActiveCodingIsCountedAndIdleExcluded() {
        var tr = tracker()
        tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
        tr.observe(.input(at: 1))
        tr.observe(.input(at: 61))
        let bd = tr.breakdown(in: 0..<100)
        assertNear(bd[.coding] ?? 0, 99)
    }

    func testShortGapInEditorStillCounts() {
        var tr = tracker()
        tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
        tr.observe(.input(at: 0))
        tr.observe(.idleReadout(idleSeconds: 30, at: 30))
        assertNear(tr.breakdown(in: 0..<90)[.coding] ?? 0, 90)
    }

    func testLongIdleBeyondThresholdExcluded() {
        var tr = tracker()
        tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
        tr.observe(.input(at: 0))
        tr.observe(.idleReadout(idleSeconds: 60, at: 600))
        assertNear(tr.breakdown(in: 0..<600)[.coding] ?? 0, 300)
    }

    func testPresenceVideoCountsWithoutInput() {
        var tr = tracker()
        tr.observe(.foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 0))
        assertNear(tr.breakdown(in: 0..<600)[.watching] ?? 0, 600)
    }

    func testScreenLockIsBlackout() {
        var tr = tracker()
        tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
        tr.observe(.input(at: 0))
        tr.observe(.sleep(at: 30))
        tr.observe(.wake(at: 330))
        tr.observe(.input(at: 340))
        let bd = tr.breakdown(in: 0..<400)
        assertNear(bd[.coding] ?? 0, 90)
        XCTAssertNil(bd[.untracked], "blackout must never accrue to any category")
    }

    func testWindowTitleSplitting() {
        var tr = tracker()
        tr.observe(.foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 0))
        tr.observe(.input(at: 0))
        tr.observe(.foreground(app: "Safari", windowTitle: "Example — An article", at: 100))
        tr.observe(.input(at: 105))
        let bd = tr.breakdown(in: 0..<200)
        assertNear(bd[.watching] ?? 0, 100)
        assertNear(bd[.browsing] ?? 0, 60) // browsing threshold 60s: active 105..165
    }

    func testCurrentActivityOverlay() {
        var tr = tracker()
        tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
        tr.observe(.input(at: 0))
        XCTAssertEqual(tr.currentActivity(at: 30)?.state, .active)
        XCTAssertEqual(tr.currentActivity(at: 30)?.category, .coding)
        XCTAssertEqual(tr.currentActivity(at: 600)?.state, .idle)
    }

    func testSegmentsAreContiguous() {
        var tr = tracker()
        tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
        tr.observe(.input(at: 0))
        tr.observe(.foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 120))
        tr.observe(.sleep(at: 200))
        tr.observe(.wake(at: 300))
        let segs = tr.segments(in: 0..<360)
        XCTAssertFalse(segs.isEmpty)
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i].start, segs[i - 1].end)
        }
    }

    func testDeterminismBatchInvariance() {
        let events: [Observation] = [
            .foreground(app: "Xcode", windowTitle: nil, at: 0),
            .input(at: 1),
            .foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 50),
            .input(at: 60),
            .idleReadout(idleSeconds: 30, at: 120),
            .sleep(at: 200),
            .wake(at: 300),
        ]
        var incremental = tracker()
        for event in events { incremental.observe(event) }
        XCTAssertEqual(tracker(events).breakdown(in: 0..<360), incremental.breakdown(in: 0..<360))
    }

    func testDefaultClassifierMappings() {
        let classify = DefaultRules.classifier()
        XCTAssertEqual(classify("Xcode", nil), .coding)
        XCTAssertEqual(classify("Safari", "YouTube — Trailer"), .watching)
        XCTAssertEqual(classify("Safari", "Example — An article"), .browsing)
        XCTAssertEqual(classify("Slack", "#eng"), .chatting)
        XCTAssertEqual(classify("SomeUnknownApp", nil), .untracked)
    }
}