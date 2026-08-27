import XCTest
@testable import FocusTrackerAdapter
@testable import FocusTrackerStore
import FocusTrackerCore

/// Integration spec for the tracking loop's persistence contract (ADR-0006):
/// data written on previous days must survive BOTH an app relaunch and a
/// midnight rollover while the app keeps running.
@MainActor
final class TrackControllerPersistenceTests: XCTestCase {

    private var storePath: String!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        storePath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fx-ctrl-\(UUID().uuidString).sqlite")
        store = try SQLiteStore(path: storePath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: storePath)
        try? FileManager.default.removeItem(atPath: storePath + "-wal")
        try? FileManager.default.removeItem(atPath: storePath + "-shm")
    }

    // Time reference: day1 = 2026-08-26 local. Noon timestamps.
    private var day1: Instant {
        var cal = Calendar.current
        cal.locale = nil
        let comps = DateComponents(year: 2026, month: 8, day: 26, hour: 12)
        return cal.date(from: comps)!.timeIntervalSince1970
    }

    private var day2: Instant { day1 + 86_400 }

    /// Seeds a focused coding hour on day-1 morning (09:00–10:00 local).
    private func seedDay1Activity() throws {
        let morning = day1 - 3 * 3600   // 09:00 vs the 12:00 reference clock
        try store.append(.foreground(app: "Xcode", windowTitle: nil, at: morning))
        try store.append(.input(at: morning))
        try store.append(.input(at: morning + 1800))
        try store.append(.foreground(app: "Xcode", windowTitle: nil, at: morning + 3599))
    }

    /// THE bug: the app runs past midnight; the Week tab must still show
    /// yesterday. Previously the rollover trimmed yesterday's raw events
    /// from memory and the Week view (derived from memory) zeroed out.
    func testWeekKeepsYesterdayAfterMidnightRollover() throws {
        try seedDay1Activity()

        var now = day1
        let controller = TrackController(store: store) { now }
        var snapshot: TrackController.Snapshot?
        controller.onUpdate = { snapshot = $0 }
        controller.start()

        // Sanity at launch: yesterday IS today, totals visible.
        let launchDayTotal = snapshot?.week.last?.totals[.coding] ?? -1
        XCTAssertGreaterThan(launchDayTotal, 0, "day-1 activity must show at launch")

        // Midnight passes while the app is running.
        now = day2
        controller.tick()   // triggers rollOverDayIfNeeded
        controller.rebuildWeekly()

        let yesterdayTotal = snapshot?.week.first(where: {
            TrackController.startOfDay(for: $0.dayStart) == TrackController.startOfDay(for: day1)
        })?.totals[.coding] ?? -1
        XCTAssertGreaterThan(yesterdayTotal, 0,
            "after midnight, yesterday's totals must persist in the Week view")

        // And the raw log is intact for future recomputation.
        XCTAssertEqual(try store.observationCount() >= 4, true)
        controller.stop()
    }

    /// Relaunch path: a fresh controller over the same store must restore
    /// yesterday into the Week view (crash/restart durability, ADR-0006).
    func testRelaunchRestoresPreviousDays() throws {
        try seedDay1Activity()

        let controller = TrackController(store: store) { [day2] in day2 }
        var snapshot: TrackController.Snapshot?
        controller.onUpdate = { snapshot = $0 }
        controller.start()

        let yesterday = snapshot?.week.first(where: {
            TrackController.startOfDay(for: $0.dayStart) == TrackController.startOfDay(for: day1)
        })?.totals[.coding] ?? -1
        XCTAssertGreaterThan(yesterday, 0, "previous day must appear after relaunch")
        controller.stop()
    }
}
