import SwiftUI
import AppKit
import Combine
import FocusTrackerCore
import FocusTrackerAdapter

/// The one published object the popover renders; replaced wholesale on each
/// controller tick (~5s). ADR-0002 in action: everything shown is derived
/// from core queries — no duplicate counters.
final class MenuModel: ObservableObject {
    @Published var snapshot: TrackController.Snapshot?

    func apply(_ s: TrackController.Snapshot) {
        self.snapshot = s
    }
}

/// Popover root: single segmented surface (ADR-0007).
struct RootView: View {
    @ObservedObject var model: MenuModel
    let controllerProvider: () -> TrackController?
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Today").tag(0)
                Text("Week").tag(1)
                Text("Settings").tag(2)
            }
            .pickerStyle(.segmented)
            .padding([.top, .horizontal], 10)
            .padding(.bottom, 6)

            Divider()

            switch tab {
            case 0:   TodayView(snapshot: model.snapshot)
            case 1:   WeekView(snapshot: model.snapshot)
            default:  SettingsView(controller: controllerProvider())
            }
        }
        .frame(width: 340, height: 360)
    }
}

// MARK: - Today (live breakdown)

struct TodayView: View {
    let snapshot: TrackController.Snapshot?

    var body: some View {
        if let s = snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(s)
                    breakdownBars(s.todayBreakdown)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        } else {
            ProgressView("Starting tracker…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ s: TrackController.Snapshot) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                Circle()
                    .fill(currentColor(s.currentActivity))
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(s)).font(.headline)
                    // Live ticker: elapsed time keeps moving at wall-clock
                    // speed instead of jumping in 5s data-refresh steps.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(subtitle(s, now: context.date.timeIntervalSince1970))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.duration(s.todayBreakdown.values.reduce(0, +)))
                        .font(.headline)
                        .monospacedDigit()
                    Text("tracked today")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func currentColor(_ activity: CurrentActivity?) -> Color {
        switch activity?.state {
        case .active:   return activity!.category.color
        case .idle:     return Color.gray.opacity(0.45)
        case .blackout: return Color.black
        default:        return Color.gray.opacity(0.3)
        }
    }

    private func title(_ s: TrackController.Snapshot) -> String {
        guard let a = s.currentActivity else { return "Nothing observed yet" }
        return a.category.displayName
    }

    private func subtitle(_ s: TrackController.Snapshot, now: Double) -> String {
        guard let a = s.currentActivity else { return "waiting for signals" }
        let elapsed = Fmt.duration(max(0, now - a.since))
        switch a.state {
        case .active:   return "focused for \(elapsed)"
        case .idle:     return "away · \(elapsed)"
        case .blackout: return "screen locked / sleeping"
        default:        return ""
        }
    }

    private func breakdownBars(_ totals: [Category: TimeInterval]) -> some View {
        let entries = totals
            .filter { $0.value > 0.5 }
            .sorted { $0.value > $1.value }
        let maxTime = entries.map(\.value).max() ?? 1

        return GroupBox(label: Label("Focused time by category", systemImage: "chart.bar.fill")) {
            if entries.isEmpty {
                Text("No focused time recorded yet today.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries, id: \.key) { category, seconds in
                        HStack(spacing: 8) {
                            Circle().fill(category.color).frame(width: 8, height: 8)
                            Text(category.displayName)
                                .font(.caption)
                                .frame(width: 72, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.gray.opacity(0.15))
                                    Capsule().fill(category.color)
                                        .frame(width: max(4, geo.size.width * seconds / maxTime))
                                }
                            }
                            .frame(height: 9)
                            Text(Fmt.duration(seconds))
                                .font(.caption).monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Week (7-day stacked bar + week-over-week deltas)

struct WeekView: View {
    let snapshot: TrackController.Snapshot?

    var body: some View {
        if let s = snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stackedChart(s.week)
                    comparison(s)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        } else {
            ProgressView("Starting tracker…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stackedChart(_ days: [TrackController.DailyTotals]) -> some View {
        GroupBox(label: Label("Last 7 days", systemImage: "calendar")) {
            let grandTotal = days.reduce(0.0) { $0 + $1.totals.values.reduce(0, +) }
            if grandTotal < 1 {
                Text("Data will build up over the coming days.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                            dayBar(day, maxDay: maxDayTotal(days))
                        }
                    }
                    legend(days)
                }
            }
        }
    }

    private func maxDayTotal(_ days: [TrackController.DailyTotals]) -> Double {
        max(1, days.map { $0.totals.values.reduce(0, +) }.max() ?? 1)
    }

    /// Bar height is proportional to that day's tracked time relative to the
    /// busiest day of the week — so a 1h day next to a 6h day looks 1:6.
    private func dayBar(_ day: TrackController.DailyTotals, maxDay: Double) -> some View {
        let entries = day.totals.filter { $0.value > 0.5 }.sorted { $0.key.rawValue < $1.key.rawValue }
        let total = entries.reduce(0.0) { $0 + $1.value }
        return VStack(spacing: 3) {
            Text(total > 60 ? Fmt.duration(total) : "")
                .font(.system(size: 8)).foregroundStyle(.secondary)
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Rectangle()
                            .fill(entry.key.color)
                            .frame(height: geo.size.height * entry.value / maxDay)
                    }
                }
                .frame(width: 30, alignment: .bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 120)
            Text(Fmt.weekdayLabel(dayStart: day.dayStart))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func legend(_ days: [TrackController.DailyTotals]) -> some View {
        var categories: Set<Category> = []
        for d in days { categories.formUnion(d.totals.keys) }
        return FlowingLegend(categories: categories.sorted { $0.rawValue < $1.rawValue })
    }

    /// Week-over-week per-category delta (PRD §11 Phase 1.1 brought forward in
    /// simple table form; the PRD allows a small delta table over big charts).
    private func comparison(_ s: TrackController.Snapshot) -> some View {
        let thisWeek = s.week.reduce(into: [Category: Double]()) { acc, day in
            for (c, v) in day.totals { acc[c, default: 0] += v }
        }
        let lastWeek = s.previousWeek
        let allCats = Set(thisWeek.keys).union(lastWeek.keys)
            .filter { (thisWeek[$0] ?? 0) + (lastWeek[$0] ?? 0) > 0.5 }
            .sorted { ($0.rawValue) < ($1.rawValue) }

        return GroupBox(label: Label("Week over week", systemImage: "arrow.up.arrow.down")) {
            if allCats.isEmpty {
                Text("Once two weeks have data, per-category trends appear here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Spacer()
                        Text("this wk").font(.caption2).bold().frame(width: 58, alignment: .trailing)
                        Text("last wk").font(.caption2).bold().frame(width: 58, alignment: .trailing)
                        Text("Δ").font(.caption2).bold().frame(width: 52, alignment: .trailing)
                    }
                    ForEach(allCats, id: \.self) { cat in
                        HStack {
                            Circle().fill(cat.color).frame(width: 7, height: 7)
                            Text(cat.displayName).font(.caption)
                            Spacer()
                            Text(Fmt.duration(thisWeek[cat] ?? 0))
                                .font(.caption).monospacedDigit().frame(width: 58, alignment: .trailing)
                            Text(Fmt.duration(lastWeek[cat] ?? 0))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                            deltaText(this: thisWeek[cat] ?? 0, last: lastWeek[cat] ?? 0)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func deltaText(this: TimeInterval, last: TimeInterval) -> some View {
        let diff = this - last
        let pct = last > 60 ? diff / last * 100 : nil
        let label: String
        if abs(diff) < 60 {
            label = "—"
        } else if let pct {
            label = String(format: "%+.0f%%", pct)
        } else {
            label = Fmt.duration(abs(diff))
        }
        return Text(label)
            .font(.caption).monospacedDigit().bold(abs(diff) >= 60)
            .foregroundColor(diff >= 0 ? .green : .orange)
    }
}

/// Simple wrap of category color-dot + name pairs.
struct FlowingLegend: View {
    let categories: [Category]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], spacing: 4) {
            ForEach(categories, id: \.self) { cat in
                HStack(spacing: 4) {
                    Circle().fill(cat.color).frame(width: 6, height: 6)
                    Text(cat.displayName).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Settings (minimal beta surface)

struct SettingsView: View {
    let controller: TrackController?
    @State private var accessibilityGranted = false
    @State private var learnedRules: [AppRule] = []
    @State private var newRuleApp = ""
    @State private var newRuleNeedle = ""
    @State private var newRuleCategory: Category = .working
    @State private var showDefaultRules = false
    @State private var paused = false

    private var editableCategories: [Category] {
        Category.allCases.filter { $0 != .untracked }
    }

    private var defaultAppRules: [(app: String, titleContains: String?, category: Category)] {
        DefaultRules.ruleTable().filter { $0.titleContains == nil }
    }

    /// Site needles are duplicated per supported browser; show each once.
    private var defaultSiteRules: [(needle: String, category: Category)] {
        var seen = Set<String>()
        var result: [(needle: String, category: Category)] = []
        for rule in DefaultRules.ruleTable() {
            guard let needle = rule.titleContains, !seen.contains(needle) else { continue }
            seen.insert(needle)
            result.append((needle, rule.category))
        }
        return result
    }

    private func refresh() {
        accessibilityGranted = controller?.accessibilityGranted ?? false
        learnedRules = controller?.learnedRules ?? []
        paused = controller?.isPaused ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(label: Label("Your rules", systemImage: "person.badge.shield.checkmark")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if learnedRules.isEmpty {
                            Text("None yet. Answer the classify prompt (or add a rule below) and that app is classified automatically from now on.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(learnedRules, id: \.self) { rule in
                                HStack(spacing: 6) {
                                    Circle().fill(rule.category.color).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(rule.app.isEmpty ? "Any app" : rule.app)
                                            .font(.caption).lineLimit(1)
                                        if let needle = rule.needle {
                                            Text("“\(needle)” in tab title / URL")
                                                .font(.caption2).foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Text(rule.category.displayName)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button {
                                        controller?.removeRule(rule)
                                        refresh()
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove this rule — the default classification applies again")
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                TextField("App (optional)", text: $newRuleApp)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                TextField("keyword in tab/URL (optional)", text: $newRuleNeedle)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                Picker("", selection: $newRuleCategory) {
                                    ForEach(editableCategories, id: \.self) { c in
                                        Text(c.displayName).tag(c)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 84)
                            }
                            HStack {
                                Button("Add rule") {
                                    controller?.learnRule(app: newRuleApp,
                                                          needle: newRuleNeedle.isEmpty ? nil : newRuleNeedle,
                                                          category: newRuleCategory)
                                    newRuleApp = ""
                                    newRuleNeedle = ""
                                    refresh()
                                }
                                .disabled(newRuleApp.trimmingCharacters(in: .whitespaces).isEmpty
                                          && newRuleNeedle.trimmingCharacters(in: .whitespaces).isEmpty)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Spacer()
                            }
                        }
                        Text("Your rules win over the built-in ones. Leave the app blank to match a keyword in any browser tab (e.g. “arxiv” → Reading); leave the keyword blank to match an app by name.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                GroupBox(label: Label("Built-in rules", systemImage: "list.bullet.rectangle")) {
                    VStack(alignment: .leading, spacing: 6) {
                        DisclosureGroup("Show the \(defaultAppRules.count) app rules and \(defaultSiteRules.count) browser rules", isExpanded: $showDefaultRules) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Apps").font(.caption2.bold()).padding(.top, 4)
                                ForEach(Array(defaultAppRules.enumerated()), id: \.offset) { _, rule in
                                    HStack(spacing: 6) {
                                        Circle().fill(rule.category.color).frame(width: 6, height: 6)
                                        Text(rule.app).font(.caption2)
                                        Spacer()
                                        Text(rule.category.displayName)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Text("Inside browsers, a tab title containing…").font(.caption2.bold()).padding(.top, 4)
                                ForEach(Array(defaultSiteRules.enumerated()), id: \.offset) { _, rule in
                                    HStack(spacing: 6) {
                                        Circle().fill(rule.category.color).frame(width: 6, height: 6)
                                        Text("“\(rule.needle)”").font(.caption2)
                                        Spacer()
                                        Text(rule.category.displayName)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Text("Anything not covered falls back to Untracked — that's when the classify prompt appears.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                        .font(.caption)
                    }
                }

                GroupBox(label: Label("Window tracking", systemImage: "eye")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(accessibilityGranted ? .green : .secondary)
                            Text(accessibilityGranted
                                 ? "Enabled — window titles are being read"
                                 : "Not enabled — tracking per app only")
                                .font(.callout)
                            Spacer()
                        }
                        if accessibilityGranted {
                            let flowing = controller?.titlesFlowing ?? false
                            HStack {
                                Image(systemName: flowing ? "text.bubble.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(flowing ? .green : .orange)
                                Text(flowing
                                     ? "Window titles flowing — tab-level splitting active"
                                     : "Titles not arriving yet — Chromium/Electron apps warm up within ~10s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        Text("Accessibility permission lets the app read the frontmost window's title so it can tell watching from reading from chatting inside one browser. Everything stays on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !accessibilityGranted {
                            Button("Open Accessibility Settings") {
                                controller?.promptForAccessibility()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }

                GroupBox(label: Label("How time is counted", systemImage: "timer")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ruleRow("Coding / Reading / Learning / Writing",
                                "active up to 5 min without input (reading code isn't idle)")
                        ruleRow("Working", "active up to 2 min without input")
                        ruleRow("Browsing / Chatting", "active up to 1 min without input")
                        ruleRow("Watching", "always active while frontmost — no input needed for video")
                        ruleRow("Screen lock / sleep", "blackout — accrues to nothing, never “working”")
                    }
                    .padding(.vertical, 2)
                }

                GroupBox(label: Label("Data & privacy", systemImage: "lock.shield")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("All data is stored locally in SQLite at:")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("~/Library/Application Support/ProductivityManager/tracker.sqlite")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("Raw observations are retained indefinitely (no auto-prune yet — arrives with CSV export in Phase 1.2). Nothing ever leaves this machine.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox(label: Label("Application", systemImage: "power")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { paused },
                                              set: { newValue in
                                                  paused = newValue
                                                  controller?.setPaused(newValue)
                                              })) {
                            Text(paused ? "Paused — tracking is off" : "Pause tracking")
                        }
                        .font(.callout)
                        .controlSize(.small)

                        Text("Pause to stop recording and sampling while keeping the app in your menu bar (it uses minimal resources while paused). Toggle back on to resume.")
                            .font(.caption).foregroundStyle(.secondary)

                        Divider()

                        Button("Quit Productivity Manager") {
                            confirmShutDown()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Text("Quitting stops tracking, frees all resources, and removes the menu-bar item. Relaunch anytime from Applications.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    /// Asks before quitting so an accidental click can't stop tracking, then
    /// terminates — `AppDelegate.applicationShouldTerminate` flushes pending
    /// timeline data first, so nothing is lost.
    private func confirmShutDown() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Productivity Manager?"
        alert.informativeText = "Tracking stops and the app leaves your menu bar. You can relaunch it anytime from Applications."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func ruleRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

