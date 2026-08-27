import SwiftUI
import AppKit
import FocusTrackerCore

// Disambiguate: ObjC exposes objc_category as `Category` via AppKit imports.
typealias Category = FocusTrackerCore.Category

// MARK: - Shared category palette (menu-bar dot, bars, legend)

/// One source of truth for each category's tint: consumed as NSColor by the
/// menu-bar dot and as SwiftUI Color by the views.
struct RGBA {
    let r: Double, g: Double, b: Double
    var a: Double = 1.0
}

extension Category {
    /// Fixed palette so a glance maps unambiguously to data.
    var rgba: RGBA {
        switch self {
        case .working:   return RGBA(r: 0.35, g: 0.34, b: 0.84)
        case .coding:    return RGBA(r: 0.04, g: 0.52, b: 1.00)
        case .reading:   return RGBA(r: 0.20, g: 0.78, b: 0.35)
        case .learning:  return RGBA(r: 0.39, g: 0.82, b: 1.00)
        case .writing:   return RGBA(r: 1.00, g: 0.84, b: 0.04)
        case .browsing:  return RGBA(r: 0.55, g: 0.57, b: 0.61)
        case .watching:  return RGBA(r: 0.75, g: 0.35, b: 0.95)
        case .chatting:  return RGBA(r: 1.00, g: 0.62, b: 0.04)
        case .untracked: return RGBA(r: 0.60, g: 0.60, b: 0.60)
        }
    }

    var color: Color {
        Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b,
              opacity: rgba.a)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }
}

// MARK: - Duration / date formatting

enum Fmt {
    /// "3h 24m", "48m", "45s"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
        } else if s >= 60 {
            return String(format: "%dm %02ds", s / 60, s % 60)
        }
        return "\(s)s"
    }

    /// "14:05–14:32"
    static func range(_ start: Double, _ end: Double) -> String {
        "\(clock(start))–\(clock(end))"
    }

    static func clock(_ epoch: Double) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func weekdayLabel(dayStart: Double) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: dayStart))
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f
    }()
}