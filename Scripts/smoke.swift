import FocusTrackerCore

// MARK: - Minimal assertion harness (Foundation-free)

/// A tiny stand-in for XCTest so the core can be verified with plain `swiftc`
/// (see README). `check` prints PASS/FAIL; any failure aborts with a non-zero
/// exit via `fatalError`, so a run only completes green if everything holds.
struct Smoke {
    static var checks = 0
    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        checks += 1
        if condition {
            print("  PASS  \(name)")
        } else {
            print("  FAIL  \(name)  \(detail)")
            fatalError("smoke test failed at '\(name)': \(detail)")
        }
    }
    static func near(_ a: Double, _ b: Double, _ epsilon: Double = 1.5) -> Bool {
        abs(a - b) <= epsilon
    }
}

func makeDefaultTracker(_ observations: [Observation] = []) -> Tracker {
    Tracker(observations: observations, classify: DefaultRules.classifier(), activityModel: DefaultRules.activityModel())
}

@main
struct Main {
    static func main() {
        print("Running core smoke tests (Foundation-free, plain swiftc)…")

        // 1) Active coding time is counted; idle is excluded.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
            tr.observe(.input(at: 1))
            tr.observe(.input(at: 61))
            let bd = tr.breakdown(in: 0..<100)
            Smoke.check("coding counted", Smoke.near(bd[.coding] ?? 0, 99), "coding=\(bd[.coding] ?? 0)")
        }

        // 2) Short no-input gap in an editor = reading code, still counted.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
            tr.observe(.input(at: 0))
            tr.observe(.idleReadout(idleSeconds: 30, at: 30))
            let bd = tr.breakdown(in: 0..<90)
            Smoke.check("editor no-input gap still active", Smoke.near(bd[.coding] ?? 0, 90), "coding=\(bd[.coding] ?? 0)")
        }

        // 3) Idle past the threshold is excluded.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
            tr.observe(.input(at: 0))
            tr.observe(.idleReadout(idleSeconds: 60, at: 600))
            let bd = tr.breakdown(in: 0..<600)
            Smoke.check("idle beyond threshold excluded", Smoke.near(bd[.coding] ?? 0, 300), "coding=\(bd[.coding] ?? 0)")
            Smoke.check("idle never approaches full window", (bd[.coding] ?? 0) < 600)
        }

        // 4) Presence-based video counts with NO input.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 0))
            let bd = tr.breakdown(in: 0..<600)
            Smoke.check("video presence counts without input", Smoke.near(bd[.watching] ?? 0, 600), "watching=\(bd[.watching] ?? 0)")
        }

        // 5) Screen lock is blackout — never credited to any category.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
            tr.observe(.input(at: 0))
            tr.observe(.sleep(at: 30))
            tr.observe(.wake(at: 330))
            tr.observe(.input(at: 340))
            let bd = tr.breakdown(in: 0..<400)
            Smoke.check("blackout not credited to coding", Smoke.near(bd[.coding] ?? 0, 90), "coding=\(bd[.coding] ?? 0)")
            Smoke.check("blackout not in untracked", bd[.untracked] == nil)
        }

        // 6) One app splits into multiple categories by window title.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 0))
            tr.observe(.input(at: 0))
            tr.observe(.foreground(app: "Safari", windowTitle: "Example — An article", at: 100))
            tr.observe(.input(at: 105))
            let bd = tr.breakdown(in: 0..<200)
            Smoke.check("browser split: watching", Smoke.near(bd[.watching] ?? 0, 100), "watching=\(bd[.watching] ?? 0)")
            Smoke.check("browser split: browsing", Smoke.near(bd[.browsing] ?? 0, 60), "browsing=\(bd[.browsing] ?? 0)")
        }

        // 7) Live overlay: active now.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
            tr.observe(.input(at: 0))
            let now = tr.currentActivity(at: 30)
            Smoke.check("overlay category=coding", now?.category == .coding)
            Smoke.check("overlay state=active", now?.state == .active, "state=\(String(describing: now?.state))")
            Smoke.check("overlay since=0", now?.since == 0, "since=\(String(describing: now?.since))")
        }

        // 8) Live overlay: quiet (idle) long after last input.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
            tr.observe(.input(at: 0))
            let now = tr.currentActivity(at: 600)
            Smoke.check("overlay goes idle past threshold", now?.state == .idle, "state=\(String(describing: now?.state))")
        }

        // 9) Segments are contiguous and non-overlapping.
        do {
            var tr = makeDefaultTracker()
            tr.observe(.foreground(app: "Xcode", windowTitle: nil, at: 0))
            tr.observe(.input(at: 0))
            tr.observe(.foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 120))
            tr.observe(.sleep(at: 200))
            tr.observe(.wake(at: 300))
            let segs = tr.segments(in: 0..<360)
            Smoke.check("timeline not empty", !segs.isEmpty)
            var contiguous = true
            for i in 1..<segs.count where segs[i].start != segs[i - 1].end { contiguous = false }
            Smoke.check("segments contiguous & non-overlapping", contiguous)
        }

        // 10) Determinism: batch vs incremental input give identical output.
        do {
            let events: [Observation] = [
                .foreground(app: "Xcode", windowTitle: nil, at: 0),
                .input(at: 1),
                .foreground(app: "Safari", windowTitle: "YouTube — Trailer", at: 50),
                .input(at: 60),
                .idleReadout(idleSeconds: 30, at: 120),
                .sleep(at: 200),
                .wake(at: 300),
            ]
            let batched = makeDefaultTracker(events).breakdown(in: 0..<360)
            var incremental = makeDefaultTracker()
            for event in events { incremental.observe(event) }
            let streamed = incremental.breakdown(in: 0..<360)
            Smoke.check("batch == incremental (determinism)", batched == streamed)
        }

        // 11) Default classification rules.
        let classify = DefaultRules.classifier()
        Smoke.check("classify Xcode → coding", classify("Xcode", nil) == .coding)
        Smoke.check("classify YouTube → watching", classify("Safari", "YouTube — Trailer") == .watching)
        Smoke.check("classify article → browsing", classify("Safari", "Example — An article") == .browsing)
        Smoke.check("classify Slack → chatting", classify("Slack", "#eng") == .chatting)
        Smoke.check("classify unknown → untracked", classify("SomeUnknownApp", nil) == .untracked)

        print("✔ all \(Smoke.checks) smoke checks passed")
    }
}