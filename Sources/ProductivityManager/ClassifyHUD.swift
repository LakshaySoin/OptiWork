import AppKit
import SwiftUI
import FocusTrackerCore
import FocusTrackerAdapter

/// A lightweight, non-activating prompt in the upper-right of the screen that
/// appears when the tracker is accruing time to `untracked` — i.e. the active
/// app/tab matched no classification rule. The user classifies *in the moment*
/// ("what am I doing in X right now?") instead of reconstructing from a
/// timestamps-only log later.
///
/// Behavior contract:
/// - Only shows while the current activity is active + untracked.
/// - Auto-dismisses after ~45s, and hides immediately once tracking becomes
///   recognized, the user goes idle, or the screen locks.
/// - Never re-prompts for the same app within a 10-minute cooldown — quick,
///   not nagging.
/// - Picking a category applies a correction spanning the current untracked
///   stretch, exactly like the (removed) session drill-down did, but before
///   the memory fades. (ADR-0005 correction mechanics, proactive delivery.)
@MainActor
final class ClassifyHUD {

    /// Called with (app, start, end, category) when the user classifies a span.
    var onClassify: ((String, Instant, Instant, Category) -> Void)?

    private var panel: NSPanel?
    private var since: Instant = 0
    private var lastPrompted: [String: Instant] = [:]
    private var promptedApp: String?
    private var dismissTimer: Timer?

    private static let cooldown: TimeInterval = 600
    private static let autoDismiss: TimeInterval = 45

    /// Inspects each controller tick. Safe to call on every snapshot.
    func evaluate(_ snapshot: TrackController.Snapshot) {
        guard let a = snapshot.currentActivity,
              a.state == .active,
              a.category == .untracked,
              let app = snapshot.foregroundApp,
              !app.isEmpty else {
            hide()
            return
        }

        // Already showing for this app: leave it up. This MUST come before the
        // cooldown check — after we show(), the entry we just recorded would
        // otherwise make the next tick's cooldown check hide the panel within
        // one 5s interval, long before the 45s auto-dismiss.
        if panel?.isVisible == true, promptedApp == app { return }

        // Cooldown: the same app is only asked about once per 10 minutes.
        lastPrompted = lastPrompted.filter { snapshot.now - $0.value < Self.cooldown }
        if let last = lastPrompted[app], snapshot.now - last < Self.cooldown {
            return
        }

        lastPrompted[app] = snapshot.now
        promptedApp = app
        since = a.since
        show(app: app)
    }

    // MARK: Panel

    private func show(app: String) {
        hide()
        let content = NSHostingView(rootView: HUDContent(app: app) { [weak self] category in
            guard let self else { return }
            let end = Date().timeIntervalSince1970
            self.onClassify?(app, self.since, end, category)
            self.hide()
        })

        let panel: NSPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = content
        panel.level = NSWindow.Level.floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = true
        panel.collectionBehavior = NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary])
        panel.ignoresMouseEvents = false

        // Upper-right, tucked just below the menu bar.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let size = content.fittingSize
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16,
                                     y: vf.maxY - size.height - 8))

        panel.orderFrontRegardless()
        self.panel = panel

        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.autoDismiss, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
        promptedApp = nil
    }
}

// MARK: - HUD content

private struct HUDContent: View {
    let app: String
    let onPick: (Category) -> Void

    private let choices: [Category] = [
        .coding, .reading, .writing, .learning, .working,
        .browsing, .watching, .chatting,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Untracked activity", systemImage: "questionmark.circle")
                .font(.headline)
            Text("What are you doing in \(app)?")
                .font(.callout)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 6)], spacing: 6) {
                ForEach(choices, id: \.self) { category in
                    Button {
                        onPick(category)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(category.color).frame(width: 8, height: 8)
                            Text(category.displayName).font(.caption)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Your pick is applied to this time span and feeds every view — no need to correct it later.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(.background)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3))
        .frame(width: 300)
    }
}
