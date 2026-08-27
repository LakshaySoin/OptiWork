import XCTest
@testable import FocusTrackerCore

/// Override semantics (ADR-0005): user corrections are overlays on the
/// derived timeline — the raw observation log stays immutable.
final class OverrideTests: XCTestCase {

    private func tracker(_ observations: [Observation], overrides: [CategoryOverride] = []) -> Tracker {
        Tracker(observations: observations, overrides: overrides,
                classify: DefaultRules.classifier(),
                activityModel: DefaultRules.activityModel())
    }

    private func assertNear(_ a: TimeInterval, _ b: TimeInterval, _ msg: String = "") {
        XCTAssertEqual(a, b, accuracy: 1.5, msg)
    }

    /// Base trace: 0..200 coding (input at 0 and 100), then 200..400 YouTube.
    private func baseObservations() -> [Observation] {
        [
            .foreground(app: "Xcode", windowTitle: nil, at: 0),
            .input(at: 0),
            .input(at: 100),
            .foreground(app: "Google Chrome", windowTitle: "funny cats - YouTube", at: 200),
            .foreground(app: "Google Chrome", windowTitle: "funny cats - YouTube", at: 399),
        ]
    }

    func testOverrideRecategorizesWholeSegment() {
        var tr = tracker(baseObservations())
        let bd0 = tr.breakdown(in: 0..<400)
        assertNear(bd0[.coding] ?? 0, 200)
        assertNear(bd0[.watching] ?? 0, 200)

        // User says: 0..200 was NOT coding, it was writing.
        tr.applyOverride(CategoryOverride(start: 0, end: 200, category: .writing))

        let bd = tr.breakdown(in: 0..<400)
        assertNear(bd[.writing] ?? 0, 200, "overridden span accrues to new category")
        XCTAssertNil(bd[.coding], "old category must disappear")
        assertNear(bd[.watching] ?? 0, 200, "untouched segment unchanged")
    }

    func testOverrideSplitsPartialOverlap() {
        var tr = tracker(baseObservations())
        // Override only the middle hour-ish slice 100..300.
        tr.applyOverride(CategoryOverride(start: 100, end: 300, category: .reading))

        let bd = tr.breakdown(in: 0..<400)
        assertNear(bd[.coding] ?? 0, 100, "pre-override coding keeps original label")
        assertNear(bd[.reading] ?? 0, 200, "overridden span recategorized")
        assertNear(bd[.watching] ?? 0, 100, "post-override watching keeps original label")

        // Timeline stays contiguous and non-overlapping. Pieces: coding(0..100),
        // reading(100..300, fused from both sides of the boundary), watching(300..400).
        let segs = tr.segments(in: 0..<400)
        XCTAssertEqual(segs.map(\.category), [.coding, .reading, .watching])
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i].start, segs[i - 1].end)
        }
    }

    func testOverrideDoesNotTouchIdleOrBlackout() {
        var tr = tracker(baseObservations())
        tr.observe(.sleep(at: 400))
        tr.observe(.wake(at: 500))
        // Override spans the blackout stretch too.
        tr.applyOverride(CategoryOverride(start: 350, end: 450, category: .reading))

        let segs = tr.segments(in: 0..<600)
        let blackout = segs.first { $0.state == .blackout }
        XCTAssertNotNil(blackout)
        XCTAssertEqual(blackout?.category, .untracked, "blackout state is never recolored")
        // Override spans 350..450: only the active 350..400 slice recolors;
        // the blackout 400..500 accrues to nothing regardless.
        let bd = tr.breakdown(in: 0..<500)   // bounded before wake so the live tail doesn't extend watching
        assertNear(bd[.reading] ?? 0, 50)
        assertNear(bd[.watching] ?? 0, 150)
    }

    func testLastOverrideWinsOnSameRange() {
        var tr = tracker(baseObservations())
        tr.applyOverride(CategoryOverride(start: 0, end: 200, category: .writing))
        tr.applyOverride(CategoryOverride(start: 0, end: 200, category: .reading))
        let bd = tr.breakdown(in: 0..<400)
        assertNear(bd[.reading] ?? 0, 200)
        XCTAssertNil(bd[.writing])
    }

    func testOverrideSurvivesRebuild() {
        let obs = baseObservations()
        let overrides = [CategoryOverride(start: 0, end: 200, category: .writing)]
        let batched = tracker(obs, overrides: overrides).breakdown(in: 0..<400)
        var incremental = tracker(obs)
        for o in overrides { incremental.applyOverride(o) }
        XCTAssertEqual(batched, incremental.breakdown(in: 0..<400), "overrides are part of deterministic replay")
    }
}
