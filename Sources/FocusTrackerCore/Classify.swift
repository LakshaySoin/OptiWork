/// The classification seam (ADR-0005): maps a frontmost (app, window title)
/// to a category. Curated defaults ship in `DefaultRules`; per-user overrides
/// and learned rules will plug in behind this same signature later.
public typealias Classifier = (String, String?) -> Category

/// The per-category activity model provider (ADR-0003): decides whether a
/// category is input-tolerated or presence-based. Exposed as its own callable
/// so the same category can carry a user-tunable threshold.
public typealias ActivityModelProvider = (Category) -> ActivityModel

/// Curated default classification rules used on day one ("autonomous-first").
///
/// Order matters: the first matching rule wins. A rule matches on the app name
/// and, when a `titleContains` is set, the (lowercased) window title — this is
/// what lets a browser split into watching/reading/chatting by tab (ADR-0005).
public enum DefaultRules {
    /// Builds the curated default rule table. Exposed via `ruleTable()` so the
    /// Settings surface can show users exactly why something classifies as it
    /// does (ADR-0010).
    public static func buildRules() -> [(app: String, titleContains: String?, category: Category)] {
        // Site-level title needles shared by every supported browser. A tab
        // whose window title contains the needle maps to the category — this
        // is what splits one browser into coding/learning/chatting by task.
        let siteRules: [(needle: String, category: Category)] = [
            // Video platforms → watching. Needles match BOTH tab titles and
            // raw URLs, so short-link hosts (youtu.be) belong here too.
            ("youtube", .watching),
            ("youtu.be", .watching),
            ("netflix", .watching),
            ("hulu", .watching),
            ("disney+", .watching),
            ("twitch", .watching),
            // Coding platforms / practice → coding.
            ("leetcode", .coding),
            ("neetcode", .coding),
            ("hackerrank", .coding),
            ("codeforces", .coding),
            ("codewars", .coding),
            ("github", .coding),
            ("gitlab", .coding),
            ("bitbucket", .coding),
            ("stack overflow", .coding),
            ("stackoverflow", .coding),
            ("developer.mozilla", .coding),
            // AI-assisted study/research → learning.
            ("chatgpt", .learning),
            ("openai", .learning),
            ("claude", .learning),
            ("anthropic", .learning),
            ("perplexity", .learning),
            ("coursera", .learning),
            ("udemy", .learning),
            ("khan academy", .learning),
            ("khanacademy", .learning),
            ("wikipedia", .learning),
            // Books & long-form reading → reading. "pdf" catches both URLs
            // and tab titles of rendered documents; free-library hosts too.
            ("pdf", .reading),
            (".epub", .reading),
            ("ebook", .reading),
            ("archive.org", .reading),
            ("gutenberg", .reading),
            ("openlibrary", .reading),
            ("wikibooks", .reading),
            ("readthedocs", .reading),
            ("medium.com", .reading),
            ("substack", .reading),
            // Team chat in a tab is still chatting. Note: tab titles show the
            // product NAME ("Microsoft Teams"), not URLs — needles must match
            // what actually renders in the window title bar.
            ("slack", .chatting),
            ("microsoft teams", .chatting),
            ("gmail", .chatting),
            ("mail.google", .chatting),
            ("outlook", .chatting),
            // Docs & project tools → working/writing.
            ("google docs", .working),
            ("google sheets", .working),
            ("google slides", .working),
            ("docs.google", .working),
            ("sheets.google", .working),
            ("slides.google", .working),
            ("linear", .working),
            ("jira", .working),
            ("atlassian", .working),
            ("confluence", .working),
            ("asana", .working),
            ("trello", .working),
            ("notion", .writing),
        ]

        // Browsers get a generic fallback when no title needle matches.
        let browsers = ["safari", "chrome", "firefox", "edge", "brave", "arc",
                        "opera", "vivaldi", "dia"]

        var rules: [(app: String, titleContains: String?, category: Category)] = [
            // Dedicated single-purpose apps. App names are matched exactly or
            // by containment, because NSWorkspace reports localized display
            // names like "Google Chrome" or "Code".
            ("xcode", nil, .coding),
            ("visual studio code", nil, .coding),
            ("code", nil, .coding),
            ("cursor", nil, .coding),
            ("zed", nil, .coding),
            ("sublime text", nil, .coding),
            ("vim", nil, .coding),
            ("neovim", nil, .coding),
            ("terminal", nil, .coding),
            ("iterm", nil, .coding),
            ("warp", nil, .coding),
            ("ghostty", nil, .coding),
            ("kitty", nil, .coding),
            ("alacritty", nil, .coding),
            ("textedit", nil, .writing),
            ("notes", nil, .writing),
            ("pages", nil, .writing),
            ("obsidian", nil, .writing),
            ("notion", nil, .writing),   // desktop app
            ("preview", nil, .reading),
            ("books", nil, .reading),
            ("discord", nil, .chatting),
            ("slack", nil, .chatting),
            ("messages", nil, .chatting),
            ("facetime", nil, .chatting),
            ("zoom", nil, .chatting),
            ("teams", nil, .chatting),
            // Music/audio apps deliberately fall OUTSIDE every rule: listening
            // is not watching (see ClassifierSpecTests). Video players stay.
            ("tv", nil, .watching),
            ("quicktime player", nil, .watching),
            ("vlc", nil, .watching),
            ("iina", nil, .watching),
            ("keynote", nil, .working),
            ("word", nil, .working),
            ("excel", nil, .working),
            ("powerpoint", nil, .working),
        ]

        // Browser rules: one entry per (browser × site needle), then the
        // no-title / unmatched-title fallback.
        for browser in browsers {
            for site in siteRules {
                rules.append((app: browser, titleContains: site.needle, category: site.category))
            }
            rules.append((app: browser, titleContains: nil, category: .browsing))
        }

        return rules
    }

    /// The full curated default rule table (browser-expanded), for display in
    /// Settings (ADR-0010).
    public static func ruleTable() -> [(app: String, titleContains: String?, category: Category)] {
        buildRules()
    }

    public static func classifier() -> Classifier {
        let rules = buildRules()
        return { app, title in
            let appLower = app.lowercased()
            let titleLower = title?.lowercased()
            for rule in rules {
                // Display names carry context ("Google Chrome"), so a rule's
                // key may match either exactly or as a substring of the
                // reported name. Title needles stay exact-contains.
                guard appLower == rule.app || appLower.contains(rule.app) else { continue }
                if let needle = rule.titleContains {
                    if let t = titleLower, t.contains(needle) {
                        return rule.category
                    }
                } else {
                    return rule.category
                }
            }
            return .untracked
        }
    }

    /// The default classifier preceded by persisted learned app rules
    /// (ADR-0010): when the user answers the classify HUD for an app, that
    /// mapping is remembered and wins over curated defaults on every future
    /// observation — so the question is asked once, not every time.
    public static func classifier(learned: [AppRule]) -> Classifier {
        let base = classifier()
        let learnedRules = learned.map { rule in
            (key: rule.app.lowercased(), needle: rule.needle?.lowercased(), category: rule.category)
        }
        return { app, title in
            let appLower = app.lowercased()
            let titleLower = title?.lowercased()
            for rule in learnedRules {
                // Empty app key = "any app" (keyword-only rules).
                if !rule.key.isEmpty,
                   appLower != rule.key, !appLower.contains(rule.key) {
                    continue
                }
                // A needle rule additionally requires the title/URL match.
                if let needle = rule.needle {
                    if let t = titleLower, t.contains(needle) {
                        return rule.category
                    }
                } else if !rule.key.isEmpty {
                    return rule.category
                }
            }
            return base(app, title)
        }
    }

    public static func activityModel() -> ActivityModelProvider {
        return { category in
            switch category {
            case .watching:
                return .presenceActive
            default:
                // Interactive tools tolerate longer gaps (reading code isn't idle).
                switch category {
                case .coding, .reading, .learning, .writing:
                    return .inputActive(idleThreshold: 300)
                case .working:
                    return .inputActive(idleThreshold: 120)
                default:
                    return .inputActive(idleThreshold: 60)
                }
            }
        }
    }
}