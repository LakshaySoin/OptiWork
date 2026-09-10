import XCTest
@testable import FocusTrackerCore

/// Classification specification (ADR-0005): curated default rules must map
/// real-world frontmost situations to the right activity category.
/// Tests here are the acceptance criteria for day-one autonomy.
final class ClassifierSpecTests: XCTestCase {

    let classify = DefaultRules.classifier()

    // MARK: Music apps are NOT watching

    /// Listening to music on Spotify is not watching video: it must not
    /// accrue to Watching. Until we model a dedicated listening category,
    /// music apps deliberately fall outside every rule (untracked).
    func testMusicAppsAreNotWatching() {
        XCTAssertEqual(classify("Spotify", nil), .untracked)
        XCTAssertEqual(classify("Music", nil), .untracked)
        XCTAssertEqual(classify("Apple Music", nil), .untracked)
        // Even with a video-suggesting title, an audio-first app stays untracked.
        XCTAssertEqual(classify("Spotify", "Some Video Podcast"), .untracked)
    }

    // MARK: Web-app splitting inside browsers (requires window titles)

    /// The user's reported case: solving problems on leetcode.com in Chrome
    /// is coding, not browsing.
    func testLeetCodeInBrowserIsCoding() {
        XCTAssertEqual(classify("Google Chrome", "Two Sum - LeetCode"), .coding)
        XCTAssertEqual(classify("Google Chrome", "NEETCODE 150 - LeetCode"), .coding)
        XCTAssertEqual(classify("Safari", "Daily Coding Problem — LeetCode"), .coding)
    }

    /// AI-assistant sites are study/research sessions → learning.
    func testAIAssistantSitesAreLearning() {
        XCTAssertEqual(classify("Google Chrome", "ChatGPT - Explain Swift actors"), .learning)
        XCTAssertEqual(classify("Google Chrome", "Claude - debugging help"), .learning)
        XCTAssertEqual(classify("arc", "chatgpt.com"), .learning)
    }

    /// Slack / Teams running in a browser tab is still chatting (the PRD's
    /// Gmail-in-browser case generalizes to team-chat web apps).
    func testTeamChatWebAppsAreChatting() {
        XCTAssertEqual(classify("Google Chrome", "Slack | #engineering"), .chatting)
        XCTAssertEqual(classify("Safari", "Microsoft Teams | Engineering"), .chatting)
    }

    /// Document editing and project tracking in the browser → working/writing.
    func testDocsAndPMWebAppsAreWorkish() {
        XCTAssertEqual(classify("Google Chrome", "Spec draft - Google Docs"), .working)
        XCTAssertEqual(classify("Google Chrome", "Sprint board · Linear"), .working)
        XCTAssertEqual(classify("Google Chrome", "My notes - Notion"), .writing)
        XCTAssertEqual(classify("Safari", "Project overview - Jira"), .working)
    }

    /// URLs (fetched locally from the browser's active tab) must classify
    /// exactly like their site equivalents. The adapter passes the URL as
    /// part of the window-title signal, so needles must match URL strings.
    func testURLClassification() {
        XCTAssertEqual(classify("Google Chrome", "https://www.youtube.com/watch?v=abc123"), .watching)
        XCTAssertEqual(classify("Google Chrome", "https://youtu.be/abc123"), .watching)
        XCTAssertEqual(classify("Google Chrome", "https://leetcode.com/problems/two-sum/description/"), .coding)
        XCTAssertEqual(classify("Google Chrome", "https://github.com/apple/swift/pull/12"), .coding)
        XCTAssertEqual(classify("Google Chrome", "https://chatgpt.com/c/abc-123"), .learning)
        XCTAssertEqual(classify("Safari", "https://claude.ai/chats/xyz"), .learning)
        XCTAssertEqual(classify("Google Chrome", "https://mail.google.com/mail/u/0/#inbox"), .chatting)
        XCTAssertEqual(classify("Google Chrome", "https://docs.google.com/document/d/xyz/edit"), .working)
        // Unmatched URLs stay browsing.
        XCTAssertEqual(classify("Google Chrome", "https://news.ycombinator.com/item?id=1"), .browsing)
    }

    /// Reading books and long-form text online: PDFs (the dominant book
    /// format on the web) and free-library hosts are reading, not browsing.
    func testBooksAndLibrariesAreReading() {
        XCTAssertEqual(classify("Google Chrome", "https://archive.org/details/alicesadventures"), .reading)
        XCTAssertEqual(classify("Google Chrome", "https://www.gutenberg.org/files/11/11-h/11-h.htm"), .reading)
        XCTAssertEqual(classify("Google Chrome", "https://openlibrary.org/works/OL123W"), .reading)
        XCTAssertEqual(classify("Safari", "https://example.com/books/alice.pdf"), .reading)
        XCTAssertEqual(classify("Google Chrome", "Alice in Wonderland.pdf"), .reading)
        XCTAssertEqual(classify("Google Chrome", "Lecture notes (PDF) — chapter 3"), .reading)
        XCTAssertEqual(classify("Google Chrome", "https://aws.amazon.com/whitepaper.pdf"), .reading)
    }

    /// Regression pins: video sites stay watching, generic browsing stays
    /// browsing, unknown apps stay untracked.
    func testVideoAndBrowsingPins() {
        XCTAssertEqual(classify("Google Chrome", "lofi hip hop radio - YouTube"), .watching)
        XCTAssertEqual(classify("Google Chrome", "Stranger Things - Netflix"), .watching)
        XCTAssertEqual(classify("Google Chrome", nil), .browsing)
        XCTAssertEqual(classify("Google Chrome", "Some random blog post"), .browsing)
        XCTAssertEqual(classify("RandomUnknownApp", nil), .untracked)
    }

    /// Regression pins for boundary values from production display names:
    /// exact matches AND containment variants must behave identically.
    func testDisplayNameVariants() {
        XCTAssertEqual(classify("Code", nil), .coding)
        XCTAssertEqual(classify("Code - insiders", nil), .coding)
        XCTAssertEqual(classify("iTerm2", nil), .coding)
        XCTAssertEqual(classify("Spotify", nil), .untracked)
        XCTAssertEqual(classify("Safari", nil), .browsing)
        XCTAssertEqual(classify("Firefox", nil), .browsing)
    }
}

/// Time-accounting consequences of the classification spec, tested through
/// the Tracker's public query surface (ADR-0002): classification mistakes must
/// never distort what actually accrues.
final class ClassifierConsequenceTests: XCTestCase {

    private func tracker(_ observations: [Observation] = []) -> Tracker {
        Tracker(observations: observations,
                classify: DefaultRules.classifier(),
                activityModel: DefaultRules.activityModel())
    }

    private func assertNear(_ actual: TimeInterval, _ expected: TimeInterval, _ message: String = "") {
        XCTAssertEqual(actual, expected, accuracy: 1.5, message)
    }

    /// Music listening with zero input is NOT watch-time and NOT work-time:
    /// untracked apps have an input-active model, so an untouched Spotify
    /// session accrues to nothing. (Fixes "Spotify counts as Watching".)
    func testUntouchedMusicSessionAccruesNothing() {
        var tr = tracker()
        tr.observe(.foreground(app: "Spotify", windowTitle: "Daily Mix 1", at: 0))
        tr.observe(.idleReadout(idleSeconds: 300, at: 300))
        let bd = tr.breakdown(in: 0..<600)
        XCTAssertNil(bd[.watching], "music must never accrue to watching")
        XCTAssertNil(bd[.coding], "music must never accrue to any task")
    }

    /// A YouTube tab watched hands-free for ten minutes IS watching time —
    /// presence-active means playback needs no input (PRD §6.1).
    func testHandsFreeYouTubeAccruesFully() {
        var tr = tracker()
        tr.observe(.foreground(app: "Google Chrome", windowTitle: "lofi radio - YouTube", at: 0))
        tr.observe(.idleReadout(idleSeconds: 600, at: 600))
        assertNear(tr.breakdown(in: 0..<600)[.watching] ?? 0, 600)
    }

    /// Coding on leetcode.com in the browser (input present) is coding-time.
    /// Hand-computed reference: input@10 → active until 10+300=310;
    /// idle[0–10] + active[10–200] + tail-active[200–310] ⇒ 300s coding.
    func testLeetCodeBrowserSessionIsCodingTime() {
        var tr = tracker()
        tr.observe(.foreground(app: "Google Chrome", windowTitle: "Two Sum - LeetCode", at: 0))
        tr.observe(.input(at: 10))
        tr.observe(.idleReadout(idleSeconds: 5, at: 200))
        assertNear(tr.breakdown(in: 0..<600)[.coding] ?? 0, 300)
        assertNear(tr.breakdown(in: 0..<600)[.browsing] ?? 0, 0)
    }

    /// The same browser alternating tabs splits correctly over time.
    func testAlternatingTabsSplitOverTime() {
        var tr = tracker()
        tr.observe(.foreground(app: "Google Chrome", windowTitle: "Two Sum - LeetCode", at: 0))
        tr.observe(.input(at: 0))
        tr.observe(.foreground(app: "Google Chrome", windowTitle: "lofi radio - YouTube", at: 100))
        tr.observe(.foreground(app: "Google Chrome", windowTitle: "Sprint board - Linear", at: 300))
        tr.observe(.input(at: 310))
        let bd = tr.breakdown(in: 0..<400)
        assertNear(bd[.coding] ?? 0, 100)
        assertNear(bd[.watching] ?? 0, 200)
        assertNear(bd[.working] ?? 0, 90)   // working: 120s tolerance covers 310..400
    }

    // MARK: - Learned rules (ADR-0010)

    func testLearnedRuleTakesPrecedenceAndMatchesLoosely() {
        // "MusicXYZ" matches no default rule; the learned rule must classify
        // it — including when the reported name carries extra context.
        let c = DefaultRules.classifier(learned: [AppRule(app: "musicxyz", category: .watching)])
        XCTAssertEqual(c("MusicXYZ", nil), .watching)
        XCTAssertEqual(c("MusicXYZ Helper", "Anything"), .watching)

        // Learned rules win over curated defaults for the same app.
        let c2 = DefaultRules.classifier(learned: [AppRule(app: "xcode", category: .writing)])
        XCTAssertEqual(c2("Xcode", "main.swift"), .writing)

        // Unknown apps still fall through to curated defaults.
        let c3 = DefaultRules.classifier(learned: [AppRule(app: "musicxyz", category: .watching)])
        XCTAssertEqual(c3("Xcode", nil), .coding)
        XCTAssertEqual(c3("Something Else", nil), .untracked)
    }

    func testLearnedKeywordRuleMatchesTitleAcrossApps() {
        // Keyword rules with an empty app match any app's title/URL signal —
        // this is how users cover browser tabs the defaults miss (ADR-0010).
        let c = DefaultRules.classifier(learned: [
            AppRule(app: "", needle: "arxiv", category: .reading),
            AppRule(app: "chrome", needle: "ddl", category: .working),
        ])
        XCTAssertEqual(c("Google Chrome", "Designing Data-Intensive Applications ddl"), .working)
        XCTAssertEqual(c("Safari", "arxiv.org/abs/2401.12345"), .reading)
        // No needle match → defaults apply.
        XCTAssertEqual(c("Google Chrome", "Random tab"), .browsing)
        XCTAssertEqual(c("Xcode", nil), .coding)
    }
}
