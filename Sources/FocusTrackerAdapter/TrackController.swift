import Foundation
import AppKit
import FocusTrackerCore
import FocusTrackerStore

// Disambiguate: ObjC exposes objc_category as `Category` via AppKit imports.
public typealias Category = FocusTrackerCore.Category

/// The tracking loop: samples OS signals on a fixed cadence and feeds them to
/// the pure core, durably logging every observation so restarts lose nothing
/// (ADR-0006). Publishes an immutable `Snapshot` for UI consumers (ADR-0007).
///
/// All activity-model / classification policy lives in the core via the seams;
/// this class contains **no** accounting logic of its own.
@MainActor
public final class TrackController {

    // MARK: Snapshot published to the UI

    public struct DailyTotals: Equatable, Sendable {
        public let dayStart: Instant
        public let totals: [Category: TimeInterval]
    }

    public struct Snapshot: Equatable, Sendable {
        public var now: Instant
        public var currentActivity: CurrentActivity?
        /// Per-category active time today.
        public var todayBreakdown: [Category: TimeInterval]
        /// Active session segments today, newest first (drill-down list).
        public var sessionsToday: [Segment]
        /// Last 7 days ascending (oldest first).
        public var week: [DailyTotals]
        /// The previous 7-day span aggregated (for week-over-week deltas).
        public var previousWeek: [Category: TimeInterval]
        public var accessibilityGranted: Bool
        /// Active user corrections, so the UI can mark overridden sessions.
        public var overrides: [CategoryOverride]
        /// Name of the frontmost app right now (drives the classify HUD).
        public var foregroundApp: String?
    }

    /// Called on the main thread after each sampling tick.
    public var onUpdate: ((Snapshot) -> Void)?

    // MARK: State

    public private(set) var tracker: Tracker
    private let store: SQLiteStore?
    private var timer: Timer?
    private var blackoutTokens: [NSObjectProtocol] = []
    private var currentForeground: ForegroundSnapshot?
    /// Most recent input instant implied by an idle readout; advanced-only.
    private var lastRevealedInput: Instant?
    /// Persisted user corrections (ADR-0005); fed to every Tracker build.
    private var overrides: [CategoryOverride] = []
    /// Persisted learned app rules (ADR-0010); consulted before defaults.
    /// Exposed read-only for the Settings surface.
    public private(set) var learnedRules: [AppRule] = []

    /// Injectable clock for deterministic tests: production reads the wall
    /// clock; tests pin time and advance it across midnight boundaries.
    public var clock: () -> Instant
    private var currentDayStart: Instant
    private var ticksSinceWeeklyRebuild = 0
    private var cachedWeek: [DailyTotals] = []
    private var cachedPreviousWeek: [Category: TimeInterval] = [:]

    /// Cadence of the sampling loop.
    public static let tickInterval: TimeInterval = 5

    public init(store: SQLiteStore?, clock: (() -> Instant)? = nil) {
        self.store = store
        self.clock = clock ?? { Date().timeIntervalSince1970 }
        self.currentDayStart = Self.startOfDay(for: Self.readClock(clock))
        self.tracker = Tracker(
            overrides: overrides,
            classify: DefaultRules.classifier(),
            activityModel: DefaultRules.activityModel()
        )
    }

    private static func readClock(_ clock: (() -> Instant)?) -> Instant {
        clock?() ?? Date().timeIntervalSince1970
    }

    deinit {
        if let timer { timer.invalidate() }
        for token in blackoutTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    // MARK: Lifecycle

    /// Loads recent history from disk, captures initial state, starts ticking.
    public func start(loadDaysBack: Int = 14) {
        let now = clock()
        currentDayStart = Self.startOfDay(for: now)

        if let store {
            do {
                overrides = try store.loadOverrides()
            } catch {
                NSLog("[ProductivityManager] override load failed: \(error)")
            }
            do {
                learnedRules = try store.loadRules()
            } catch {
                NSLog("[ProductivityManager] learned-rule load failed: \(error)")
            }
            do {
                let since = currentDayStart - Double(loadDaysBack) * 86_400
                let history = try store.loadObservations(since: since)
                // Rebuild unconditionally: even with no history, the tracker
                // must pick up the overrides + learned rules loaded above.
                rebuildTracker(observations: history.isEmpty ? nil : history)
            } catch {
                NSLog("[ProductivityManager] failed to load history: \(error)")
                rebuildTracker()
            }
        }

        blackoutTokens = SystemSources.observeBlackout(
            onSleep: { [weak self] in
                guard let self else { return }
                self.record(.sleep(at: self.clock()))
            },
            onWake: { [weak self] in
                guard let self else { return }
                self.record(.wake(at: self.clock()))
            }
        )

        // Initial foreground capture so time counts from launch.
        let fg = SystemSources.foreground()
        record(.foreground(app: fg?.appName ?? "", windowTitle: fg?.title, at: now))
        currentForeground = fg

        tick()
        rebuildWeekly()
        pushUpdate()

        let interval = Self.tickInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called at quit: commits the derived timeline through "now" so cold
    /// storage has a segment snapshot even mid-day (the raw log already has
    /// everything — this is an aggregation optimization, not correctness).
    public func flushAndCommit() {
        snapshotCompletedDays(through: clock())
    }

    /// Halts sampling and detaches observers (used at quit and by tests).
    public func stop() {
        timer?.invalidate()
        timer = nil
        onUpdate = nil
        for token in blackoutTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        blackoutTokens.removeAll()
    }

    // MARK: Sampling tick

    public func tick() {
        let now = clock()

        rollOverDayIfNeeded(at: now)

        // Frontmost app/window: emit `.foreground` on any change (app *or*
        // title — the browser-tab boundary that powers splitting).
        let fg = SystemSources.foreground()
        if fg != currentForeground {
            // For browsers, enrich the AX title with the active tab's URL
            // (fetched locally) — precise classification even when the title
            // is opaque or missing.
            let url = fg.flatMap { BrowserURLReader.activeURL(forApp: $0.appName) }
            let signal = ForegroundSignal.combine(axTitle: fg?.title, url: url)
            record(.foreground(app: fg?.appName ?? "", windowTitle: signal, at: now))
            currentForeground = fg
        }
        titlesFlowing = fg?.title != nil

        // Input-active accounting without Input Monitoring permission: the
        // idle readout reveals *when* input last happened (at − idleSeconds).
        // The core treats explicit `.input` events as the forward-moving
        // witness and only lets readouts pull that witness earlier, so we
        // bridge between the two contracts: whenever the revealed moment
        // advances past the previous one, real input must have occurred —
        // synthesize the `.input` event the core expects. Without this the
        // first readout pins the witness forever and everything goes idle.
        let idle = SystemSources.secondsSinceInput()
        record(.idleReadout(idleSeconds: idle, at: now))
        let revealed = now - idle
        if let previous = lastRevealedInput {
            if revealed > previous + 0.25 {
                record(.input(at: revealed))
                lastRevealedInput = revealed
            }
        } else {
            record(.input(at: revealed))
            lastRevealedInput = revealed
        }

        ticksSinceWeeklyRebuild += 1
        if ticksSinceWeeklyRebuild >= 12 {   // ~once a minute
            rebuildWeekly()
            ticksSinceWeeklyRebuild = 0
        }

        pushUpdate()
    }

    // MARK: Session overrides (ADR-0005)

    /// The classifier in force: learned app rules (ADR-0010) first, curated
    /// defaults behind them.
    private func makeClassifier() -> Classifier {
        DefaultRules.classifier(learned: learnedRules)
    }

    /// Rebuilds the tracker over its current observations with the current
    /// overrides + learned rules (used after loads and after learning).
    private func rebuildTracker(observations: [Observation]? = nil) {
        tracker = Tracker(
            observations: observations ?? tracker.observations,
            overrides: overrides,
            classify: makeClassifier(),
            activityModel: DefaultRules.activityModel()
        )
    }

    /// Persists a learned (app → category) mapping and reclassifies — the
    /// answer to the classify HUD is remembered so the user is never asked
    /// about the same app again (ADR-0010). Re-learning the same app with a
    /// different category updates the rule.
    public func learnRule(app: String, category: Category) {
        let key = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if let idx = learnedRules.firstIndex(where: { $0.app.lowercased() == key.lowercased() }) {
            learnedRules[idx] = AppRule(app: key, category: category)
        } else {
            learnedRules.append(AppRule(app: key, category: category))
        }
        if let store {
            do { try store.saveRule(AppRule(app: key, category: category)) }
            catch { NSLog("[ProductivityManager] learned-rule save failed: \(error)") }
        }
        rebuildTracker()
        rebuildWeekly()
        pushUpdate()
    }

    /// Forgets a learned rule — curated defaults apply to that app again.
    public func removeRule(app: String) {
        learnedRules.removeAll { $0.app.lowercased() == app.lowercased() }
        if let store {
            do { try store.deleteRule(app: app) }
            catch { NSLog("[ProductivityManager] learned-rule delete failed: \(error)") }
        }
        rebuildTracker()
        rebuildWeekly()
        pushUpdate()
    }

    /// Applies a user correction to a session span, persists it durably, and
    /// refreshes every derived view immediately (they all share the render
    /// pass, so Today bars / Week chart / sessions stay in sync — ADR-0002).
    public func applyOverride(start: Instant, end: Instant, category: Category) {
        let override = CategoryOverride(start: start, end: end, category: category)
        tracker.applyOverride(override)
        if let store {
            do { try store.saveOverride(override) }
            catch { NSLog("[ProductivityManager] override save failed: \(error)") }
        }
        rebuildWeekly()
        pushUpdate()
    }

    /// Removes a correction entirely — the automatic classification returns.
    public func removeOverride(start: Instant, end: Instant) {
        tracker.removeOverride(start: start, end: end)
        if let store {
            do { try store.deleteOverride(start: start, end: end) }
            catch { NSLog("[ProductivityManager] override delete failed: \(error)") }
        }
        rebuildWeekly()
        pushUpdate()
    }

    // MARK: Accessibility (ADR-0004)

    public var accessibilityGranted: Bool {
        WindowTitleReader.isTrusted(prompt: false)
    }

    /// Whether window-title reads are actually succeeding right now. When
    /// Accessibility is granted but this stays false, something is wrong
    /// beyond permissions — surfaced in Settings so failure is visible.
    public private(set) var titlesFlowing = false

    /// Triggers the OS Accessibility consent sheet (after our own explanation).
    public func promptForAccessibility() {
        _ = WindowTitleReader.isTrusted(prompt: true)
    }

    // MARK: Event recording (observe + durable append)

    private func record(_ observation: Observation) {
        tracker.observe(observation)
        if let store {
            do { try store.append(observation) }
            catch { NSLog("[ProductivityManager] append failed: \(error)") }
        }
    }

    // MARK: Snapshots & persistence

    private func pushUpdate() {
        let now = clock()
        let todayRange = currentDayStart..<Self.nextDayStart(after: currentDayStart)
        let today = tracker.breakdown(in: todayRange)
        var sessions = tracker.segments(in: todayRange).filter { $0.state == .active }
        if sessions.count > 400 {
            sessions = Array(sessions.suffix(400))
        }
        onUpdate?(Snapshot(
            now: now,
            currentActivity: tracker.currentActivity(at: now),
            todayBreakdown: today,
            sessionsToday: sessions.reversed(),
            week: cachedWeek,
            previousWeek: cachedPreviousWeek,
            accessibilityGranted: accessibilityGranted,
            overrides: overrides,
            foregroundApp: currentForeground?.appName
        ))
    }

    /// Recomputes the cached 7-day and previous-week aggregates from the
    /// in-memory tracker. Exposed for tests that drive the clock manually.
    public func rebuildWeekly() {
        let dayLen = 86_400.0
        var days: [DailyTotals] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            let start = currentDayStart - Double(offset) * dayLen
            let range = start..<Self.nextDayStart(after: start)
            days.append(DailyTotals(dayStart: start, totals: tracker.breakdown(in: range)))
        }
        cachedWeek = days

        var prev: [Category: TimeInterval] = [:]
        for offset in stride(from: 13, through: 7, by: -1) {
            let start = currentDayStart - Double(offset) * dayLen
            let range = start..<Self.nextDayStart(after: start)
            for (category, value) in tracker.breakdown(in: range) {
                prev[category, default: 0] += value
            }
        }
        cachedPreviousWeek = prev
    }

    /// Commits closed segments for fully-passed time into cold storage.
    private func snapshotCompletedDays(through upperBound: Instant) {
        guard let store, let firstAt = tracker.observations.first?.at else { return }
        let lower = Self.startOfDay(for: firstAt)
        let upper = min(upperBound, Self.nextDayStart(after: currentDayStart))
        guard upper > lower else { return }
        let range = lower..<upper
        let closed = tracker.segments(in: range)
        do { try store.replace(in: range, with: closed) }
        catch { NSLog("[ProductivityManager] snapshot failed: \(error)") }
    }

    /// At midnight: freeze yesterday's timeline into storage, then keep the
    /// rolling 14-day window in memory. Prior days MUST stay queryable — the
    /// Week view derives from the in-memory tracker, so trimming to today
    /// would zero out history every midnight (the bug this replaces).
    private func rollOverDayIfNeeded(at now: Instant) {
        let newDayStart = Self.startOfDay(for: now)
        guard newDayStart > currentDayStart else { return }
        snapshotCompletedDays(through: newDayStart)

        let windowStart = newDayStart - 13 * 86_400
        var kept = tracker.observations.filter { $0.at >= windowStart }
        // A store reload is authoritative: it also restores anything written
        // by a previous app session that this instance hasn't loaded.
        if let store,
           let reloaded = try? store.loadObservations(since: windowStart),
           !reloaded.isEmpty {
            kept = reloaded
        }
        tracker = Tracker(
            observations: kept,
            overrides: overrides,
            classify: makeClassifier(),
            activityModel: DefaultRules.activityModel()
        )
        currentDayStart = newDayStart
        rebuildWeekly()
    }

    // MARK: Time helpers

    static func now() -> Instant { Date().timeIntervalSince1970 }

    static func startOfDay(for instant: Instant) -> Instant {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: instant)).timeIntervalSince1970
    }

    static func nextDayStart(after instant: Instant) -> Instant {
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: instant))
        else { return instant + 86_400 }
        return Calendar.current.startOfDay(for: next).timeIntervalSince1970
    }
}