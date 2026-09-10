import Foundation
import SQLite3
import FocusTrackerCore

/// SQLite-backed production adapter of the `Store` seam (ADR-0006).
///
/// Stores **raw observations** (the durable log the tracker replays after a
/// relaunch — nothing is lost across restarts or crashes) and **closed
/// segments** (snapshots of completed days for cold aggregation and the later
/// override-recompute flow). Everything lives on-device.
///
/// Uses the system `libsqlite3` that ships with macOS — no third-party deps.
public final class SQLiteStore: Store {

    private var db: OpaquePointer?
    public let path: String

    /// The SDK exposes SQLITE_TRANSIENT as a C macro; recreate it for Swift.
    private static let transient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    public enum StoreError: LocalizedError, Equatable {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case bindFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let p): return "SQLiteStore: could not open \(p)"
            case .prepareFailed(let e): return "SQLiteStore: prepare failed — \(e)"
            case .stepFailed(let e): return "SQLiteStore: step failed — \(e)"
            case .bindFailed(let e): return "SQLiteStore: bind failed — \(e)"
            }
        }
    }

    enum BindingValue {
        case text(String)
        case textOrNil(String?)
        case double(Double)
    }

    /// Opens (creating if needed) the database at `path`.
    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw StoreError.openFailed(path)
        }
        self.db = db
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("CREATE TABLE IF NOT EXISTS observations (" +
                 "id INTEGER PRIMARY KEY AUTOINCREMENT," +
                 "kind TEXT NOT NULL, app TEXT, title TEXT," +
                 "idle_seconds REAL, at REAL NOT NULL);")
        try exec("CREATE INDEX IF NOT EXISTS idx_observations_at ON observations(at);")
        try exec("CREATE TABLE IF NOT EXISTS segments (" +
                 "category TEXT NOT NULL, state TEXT NOT NULL," +
                 "start REAL NOT NULL, end REAL NOT NULL," +
                 "PRIMARY KEY (start, end));")
        try exec("CREATE TABLE IF NOT EXISTS overrides (" +
                 "start REAL NOT NULL, end REAL NOT NULL," +
                 "category TEXT NOT NULL," +
                 "PRIMARY KEY (start, end));")
        try exec("CREATE TABLE IF NOT EXISTS learned_rules (" +
                 "app TEXT NOT NULL DEFAULT ''," +
                 "needle TEXT," +
                 "category TEXT NOT NULL," +
                 "UNIQUE(app, needle));")
        // One-time migration from the app-only table (pre-keyword rules).
        try? exec("INSERT OR IGNORE INTO learned_rules(app,needle,category) " +
                  "SELECT app, NULL, category FROM app_rules;")
        try? exec("DROP TABLE IF EXISTS app_rules;")
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Store conformance

    public func save(_ segment: Segment) throws {
        try transaction {
            try bindAndStep(sql: "INSERT OR REPLACE INTO segments(category,state,start,end) VALUES(?,?,?,?);",
                            binds: [.text(segment.category.rawValue), .text(segment.state.stateName),
                                    .double(segment.start), .double(segment.end)])
        }
    }

    public func segments(in range: Range<Instant>) throws -> [Segment] {
        var result: [Segment] = []
        try query(
            sql: "SELECT category,state,start,end FROM segments WHERE end > ? AND start < ? ORDER BY start ASC;",
            binds: [.double(range.lowerBound), .double(range.upperBound)]
        ) { row in
            if let s = Self.segment(fromRow: row) { result.append(s) }
        }
        return result
    }

    /// Deletes every stored segment intersecting `range` and writes `segments`
    /// back in one transaction — the override-recompute primitive (ADR-0006).
    public func replace(in range: Range<Instant>, with segments: [Segment]) throws {
        try transaction {
            try bindAndStep(sql: "DELETE FROM segments WHERE end > ? AND start < ?;",
                            binds: [.double(range.lowerBound), .double(range.upperBound)])
            for s in segments {
                try bindAndStep(sql: "INSERT OR REPLACE INTO segments(category,state,start,end) VALUES(?,?,?,?);",
                                binds: [.text(s.category.rawValue), .text(s.state.stateName),
                                        .double(s.start), .double(s.end)])
            }
        }
    }

    // MARK: - Raw observation log

    /// Durably appends one raw observation. Called on every tracked event so
    /// a crash loses nothing (ADR-0006 restart requirement).
    public func append(_ observation: Observation) throws {
        switch observation {
        case .foreground(let app, let title, let at):
            try bindAndStep(
                sql: "INSERT INTO observations(kind,app,title,idle_seconds,at) VALUES('foreground',?,?,NULL,?);",
                binds: [.text(app), .textOrNil(title), .double(at)])
        case .input(let at):
            try bindAndStep(sql: "INSERT INTO observations(kind,idle_seconds,at) VALUES('input',NULL,?);",
                            binds: [.double(at)])
        case .idleReadout(let idleSeconds, let at):
            try bindAndStep(sql: "INSERT INTO observations(kind,idle_seconds,at) VALUES('idleReadout',?,?);",
                            binds: [.double(idleSeconds), .double(at)])
        case .sleep(let at):
            try bindAndStep(sql: "INSERT INTO observations(kind,at) VALUES('sleep',?);", binds: [.double(at)])
        case .wake(let at):
            try bindAndStep(sql: "INSERT INTO observations(kind,at) VALUES('wake',?);", binds: [.double(at)])
        }
    }

    /// Loads all observations at or after `since`, oldest first — the launch
    /// path that hands history back to the `Tracker`.
    public func loadObservations(since: Instant) throws -> [Observation] {
        var result: [Observation] = []
        try query(
            sql: "SELECT kind,app,title,idle_seconds,at FROM observations WHERE at >= ? ORDER BY at ASC;",
            binds: [.double(since)]
        ) { row in
            if let o = Self.observation(fromRow: row) { result.append(o) }
        }
        return result
    }

    public func deleteObservations(before cutoff: Instant) throws {
        try bindAndStep(sql: "DELETE FROM observations WHERE at < ?;", binds: [.double(cutoff)])
    }

    public func observationCount() throws -> Int {
        var count = 0
        try query(sql: "SELECT COUNT(*) FROM observations;", binds: []) { row in
            count = Int(sqlite3_column_int64(row, 0))
        }
        return count
    }

    // MARK: - Row mapping

    private static func segment(fromRow row: OpaquePointer) -> Segment? {
        guard let category = Category(rawValue: columnText(row, 0) ?? ""),
              let state = ActivityState(stateName: columnText(row, 1) ?? "") else { return nil }
        return Segment(category: category,
                       state: state,
                       start: sqlite3_column_double(row, 2),
                       end: sqlite3_column_double(row, 3))
    }

    private static func observation(fromRow row: OpaquePointer) -> Observation? {
        let kind = columnText(row, 0) ?? ""
        let at = sqlite3_column_double(row, 4)
        switch kind {
        case "foreground":
            let app = columnText(row, 1) ?? ""
            return .foreground(app: app, windowTitle: columnText(row, 2), at: at)
        case "input":       return .input(at: at)
        case "idleReadout": return .idleReadout(idleSeconds: sqlite3_column_double(row, 3), at: at)
        case "sleep":       return .sleep(at: at)
        case "wake":        return .wake(at: at)
        default:            return nil
        }
    }

    private static func columnText(_ row: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(row, i) else { return nil }
        return String(cString: c)
    }

    // MARK: - sqlite plumbing

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw StoreError.stepFailed(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.prepareFailed(lastError())
        }
        return stmt
    }

    /// Binds values positionally (order of `binds` maps to the SQL's ?s),
    /// steps once; tolerates SQLITE_ROW for scalar selects.
    @discardableResult
    private func bindAndStep(sql: String, binds: [BindingValue]) throws -> Bool {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(binds, to: stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.stepFailed(lastError())
        }
        return rc == SQLITE_ROW
    }

    private func query(sql: String, binds: [BindingValue], consumeRow: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(binds, to: stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { consumeRow(stmt) }
            else if rc == SQLITE_DONE { break }
            else { throw StoreError.stepFailed(lastError()) }
        }
    }

    private func bind(_ values: [BindingValue], to stmt: OpaquePointer) throws {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch value {
            case .text(let s):
                rc = sqlite3_bind_text(stmt, index, s, -1, Self.transient)
            case .textOrNil(let s):
                rc = s.map { sqlite3_bind_text(stmt, index, $0, -1, Self.transient) }
                    ?? sqlite3_bind_null(stmt, index)
            case .double(let d):
                rc = sqlite3_bind_double(stmt, index, d)
            }
            guard rc == SQLITE_OK else { throw StoreError.bindFailed(lastError()) }
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func lastError() -> String {
        if let db { return String(cString: sqlite3_errmsg(db)) }
        return "no database"
    }

    // MARK: - Category overrides (ADR-0005)

    /// Upserts a user correction keyed by its (start, end) range.
    public func saveOverride(_ override: CategoryOverride) throws {
        try bindAndStep(sql: "INSERT OR REPLACE INTO overrides(start,end,category) VALUES(?,?,?);",
                        binds: [.double(override.start), .double(override.end),
                                .text(override.category.rawValue)])
    }

    public func loadOverrides() throws -> [CategoryOverride] {
        var result: [CategoryOverride] = []
        try query(sql: "SELECT start,end,category FROM overrides ORDER BY start ASC;", binds: []) { row in
            guard let category = Category(rawValue: Self.columnText(row, 2) ?? "") else { return }
            result.append(CategoryOverride(start: sqlite3_column_double(row, 0),
                                           end: sqlite3_column_double(row, 1),
                                           category: category))
        }
        return result
    }

    public func deleteOverride(start: Double, end: Double) throws {
        try bindAndStep(sql: "DELETE FROM overrides WHERE start = ? AND end = ?;",
                        binds: [.double(start), .double(end)])
    }

    // MARK: - Learned rules (ADR-0010)

    /// Upserts a learned rule keyed by (app, needle). Nil needles are stored
    /// as '' — SQLite UNIQUE treats NULLs as distinct, which would break
    /// upsert semantics for app-only rules.
    public func saveRule(_ rule: AppRule) throws {
        try bindAndStep(sql: "INSERT OR REPLACE INTO learned_rules(app,needle,category) VALUES(?,?,?);",
                        binds: [.text(rule.app), .textOrNil(rule.needle ?? ""),
                                .text(rule.category.rawValue)])
    }

    public func loadRules() throws -> [AppRule] {
        var result: [AppRule] = []
        try query(sql: "SELECT app,needle,category FROM learned_rules ORDER BY app ASC;", binds: []) { row in
            let app = Self.columnText(row, 0) ?? ""
            let needle = Self.columnText(row, 1)
            guard let category = Category(rawValue: Self.columnText(row, 2) ?? ""),
                  !(app.isEmpty && (needle == nil || needle!.isEmpty)) else { return }
            result.append(AppRule(app: app,
                                  needle: (needle?.isEmpty ?? true) ? nil : needle,
                                  category: category))
        }
        return result
    }

    /// Removes one learned rule exactly (app + needle).
    public func deleteRule(_ rule: AppRule) throws {
        try bindAndStep(sql: "DELETE FROM learned_rules WHERE app = ? COLLATE NOCASE AND needle = ?;",
                        binds: [.text(rule.app), .textOrNil(rule.needle ?? "")])
    }
}

private extension ActivityState {
    init?(stateName: String) {
        switch stateName {
        case "active": self = .active
        case "idle": self = .idle
        case "blackout": self = .blackout
        default: return nil
        }
    }

    var stateName: String {
        switch self {
        case .active: return "active"
        case .idle: return "idle"
        case .blackout: return "blackout"
        }
    }
}
