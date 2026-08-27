import XCTest
@testable import FocusTrackerAdapter
@testable import FocusTrackerStore
import FocusTrackerCore

/// The two classification signals (AX tab title + browser URL) merge into one
/// classifier input. Needles must match either part.
final class ForegroundSignalTests: XCTestCase {

    func testCombineHandlesAllCases() {
        XCTAssertEqual(ForegroundSignal.combine(axTitle: nil, url: nil), nil)
        XCTAssertEqual(ForegroundSignal.combine(axTitle: "Two Sum - LeetCode", url: nil), "Two Sum - LeetCode")
        XCTAssertEqual(ForegroundSignal.combine(axTitle: nil, url: "https://leetcode.com"), "https://leetcode.com")
        XCTAssertEqual(
            ForegroundSignal.combine(axTitle: "Two Sum - LeetCode", url: "https://leetcode.com/problems/two-sum/"),
            "Two Sum - LeetCode https://leetcode.com/problems/two-sum/")
    }

    /// Combined signals classify by EITHER part — the URL rescue path for the
    /// "watching YouTube but the app thinks I'm browsing" bug.
    func testCombinedSignalClassifies() {
        let classify = DefaultRules.classifier()
        let combined = ForegroundSignal.combine(
            axTitle: nil,
            url: "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(classify("Google Chrome", combined), .watching)

        let coding = ForegroundSignal.combine(
            axTitle: nil,
            url: "https://leetcode.com/problems/two-sum/")
        XCTAssertEqual(classify("Google Chrome", coding), .coding)
    }

    func testBrowserSupportDetection() {
        XCTAssertTrue(BrowserURLReader.supports(appName: "Google Chrome"))
        XCTAssertTrue(BrowserURLReader.supports(appName: "Safari"))
        XCTAssertTrue(BrowserURLReader.supports(appName: "Arc"))
        XCTAssertTrue(BrowserURLReader.supports(appName: "Microsoft Edge"))
        XCTAssertFalse(BrowserURLReader.supports(appName: "Xcode"))
        XCTAssertFalse(BrowserURLReader.supports(appName: "Finder"))
        XCTAssertFalse(BrowserURLReader.supports(appName: ""))
    }
}