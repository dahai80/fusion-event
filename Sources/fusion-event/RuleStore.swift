import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)

actor RuleStore {
    private var db: OpaquePointer?
    private nonisolated(unsafe) var closeHandle: OpaquePointer?
    private let dbPath: String
    private let nodeId: String
    private nonisolated(unsafe) var checkpointTask: Task<Void, Never>?
    private let checkpointIntervalSec: Int

    init(dbPath: String, nodeId: String, checkpointIntervalSec: Int = 300) {
        self.dbPath = dbPath
        self.nodeId = nodeId
        self.checkpointIntervalSec = checkpointIntervalSec
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var handle: OpaquePointer? = nil
        let openRc = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        if openRc != SQLITE_OK || handle == nil {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open rc=\(openRc)"
            FusionLog.persist.error("rulestore open fail \(msg, privacy: .public)")
            if handle != nil { sqlite3_close(handle) }
            self.db = nil
            return
        }
        self.db = handle
        self.closeHandle = handle
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=FULL;", nil, nil, nil)
        let ddl = """
            CREATE TABLE IF NOT EXISTS rules (
                rule_name      TEXT PRIMARY KEY,
                event_type     TEXT NOT NULL,
                path_pattern   TEXT,
                debounce_ms    INTEGER DEFAULT 0,
                throttle_ms    INTEGER DEFAULT 0,
                throttle_max_per_window INTEGER DEFAULT 1,
                target_agent   TEXT NOT NULL,
                target_graph_id TEXT DEFAULT '',
                enabled        INTEGER DEFAULT 1,
                max_retries    INTEGER DEFAULT 2,
                require_guard  INTEGER DEFAULT 0,
                created_at     REAL,
                updated_at     REAL
            );
            CREATE INDEX IF NOT EXISTS idx_rules_type ON rules(event_type);
            CREATE TABLE IF NOT EXISTS debounce_state (
                rule_name      TEXT PRIMARY KEY,
                last_fire_ts   INTEGER NOT NULL,
                node_id        TEXT
            );
            """
        if sqlite3_exec(handle, ddl, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            FusionLog.persist.error("rulestore ddl fail \(msg, privacy: .public)")
        } else {
            FusionLog.persist.info("rulestore ready \(dbPath, privacy: .public)")
        }
        runMigrations(handle: handle)
        if checkpointIntervalSec > 0 {
            let interval = UInt64(checkpointIntervalSec) * 1_000_000_000
            checkpointTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: interval)
                    if Task.isCancelled { break }
                    await self?.checkpoint()
                }
            }
            FusionLog.persist.info("rulestore wal checkpoint every \(checkpointIntervalSec)s (R5, F-PERSIST-2: task assigned+cancellable)")
        }
    }

    private nonisolated func runMigrations(handle: OpaquePointer?) {
        guard let handle else { return }
        var currentVersion: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                currentVersion = sqlite3_column_int(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }
        struct Migration {
            let version: Int32
            let sql: String
        }
        let migrations: [Migration] = [
            Migration(version: 1, sql: "CREATE INDEX IF NOT EXISTS idx_rules_type_v1 ON rules(event_type);")
        ]
        var applied: Int32 = currentVersion
        for m in migrations {
            guard m.version > applied else { continue }
            let rc = sqlite3_exec(handle, m.sql, nil, nil, nil)
            if rc == SQLITE_OK {
                applied = m.version
                let setVer = "PRAGMA user_version = \(m.version);"
                sqlite3_exec(handle, setVer, nil, nil, nil)
                FusionLog.persist.info("rulestore migration v\(m.version) applied (E3: versioned, no try? masking)")
            } else {
                let msg = String(cString: sqlite3_errmsg(handle))
                FusionLog.persist.error("rulestore migration v\(m.version) FAIL \(msg, privacy: .public) — abort further migrations (E3: fail visibly)")
                break
            }
        }
        if applied != currentVersion {
            FusionLog.persist.info("rulestore schema at v\(applied)")
        }
    }

    private func checkpoint() {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "rc=\(rc)"
            FusionLog.persist.error("rulestore wal_checkpoint fail \(msg, privacy: .public)")
        }
        if errMsg != nil { sqlite3_free(errMsg) }
    }

    func stopCheckpoint() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }

    deinit {
        checkpointTask?.cancel()
        if let h = closeHandle { sqlite3_close(h) }
    }

    func loadAll() -> [EventRule] {
        guard db != nil else { return [] }
        var rules: [EventRule] = []
        var stmt: OpaquePointer?
        let sql = "SELECT rule_name,event_type,path_pattern,debounce_ms,throttle_ms,throttle_max_per_window,target_agent,target_graph_id,enabled,max_retries,require_guard FROM rules;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let type = String(cString: sqlite3_column_text(stmt, 1))
                let pathCol = sqlite3_column_text(stmt, 2)
                let path = pathCol == nil ? nil : String(cString: pathCol!)
                let deb = sqlite3_column_int(stmt, 3)
                let thr = sqlite3_column_int(stmt, 4)
                let thrMax = sqlite3_column_int(stmt, 5)
                let agent = String(cString: sqlite3_column_text(stmt, 6))
                let graphCol = sqlite3_column_text(stmt, 7)
                let graph = graphCol == nil ? nil : String(cString: graphCol!)
                let en = sqlite3_column_int(stmt, 8) != 0
                let mr = sqlite3_column_int(stmt, 9)
                let rg = sqlite3_column_int(stmt, 10) != 0
                guard let et = SystemEventType(rawValue: type) else { continue }
                rules.append(
                    EventRule(
                        ruleName: name, eventType: et, pathPattern: path,
                        debounceMs: Int(deb), throttleMs: Int(thr),
                        throttleMaxPerWindow: Int(thrMax),
                        targetAgent: agent, targetGraphId: graph, enabled: en,
                        maxRetries: Int(mr), requireGuard: rg
                    ))
            }
            sqlite3_finalize(stmt)
        }
        return rules
    }

    func upsert(_ rule: EventRule) -> Bool {
        guard db != nil else { return false }
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO rules(rule_name,event_type,path_pattern,debounce_ms,throttle_ms,throttle_max_per_window,target_agent,target_graph_id,enabled,max_retries,require_guard,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(rule_name) DO UPDATE SET
                event_type=excluded.event_type,path_pattern=excluded.path_pattern,
                debounce_ms=excluded.debounce_ms,throttle_ms=excluded.throttle_ms,throttle_max_per_window=excluded.throttle_max_per_window,
                target_agent=excluded.target_agent,target_graph_id=excluded.target_graph_id,
                enabled=excluded.enabled,max_retries=excluded.max_retries,require_guard=excluded.require_guard,updated_at=excluded.updated_at;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            FusionLog.persist.error("rulestore upsert prepare fail")
            return false
        }
        sqlite3_bind_text(stmt, 1, rule.ruleName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, rule.eventType.rawValue, -1, SQLITE_TRANSIENT)
        if let p = rule.pathPattern { sqlite3_bind_text(stmt, 3, p, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int(stmt, 4, Int32(rule.debounceMs))
        sqlite3_bind_int(stmt, 5, Int32(rule.throttleMs))
        sqlite3_bind_int(stmt, 6, Int32(rule.throttleMaxPerWindow))
        sqlite3_bind_text(stmt, 7, rule.targetAgent, -1, SQLITE_TRANSIENT)
        if let g = rule.targetGraphId, !g.isEmpty { sqlite3_bind_text(stmt, 8, g, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_text(stmt, 8, "", -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 9, rule.enabled ? 1 : 0)
        sqlite3_bind_int(stmt, 10, Int32(rule.maxRetries))
        sqlite3_bind_int(stmt, 11, rule.requireGuard ? 1 : 0)
        sqlite3_bind_double(stmt, 12, now)
        sqlite3_bind_double(stmt, 13, now)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE {
            FusionLog.persist.error("rulestore upsert step fail \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return false
        }
        FusionLog.persist.info("rulestore upsert \(rule.ruleName, privacy: .public)")
        return true
    }

    func remove(_ name: String) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM rules WHERE rule_name=?;", -1, &stmt, nil) == SQLITE_OK else {
            FusionLog.persist.error("rulestore remove prepare fail")
            return false
        }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        var debStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM debounce_state WHERE rule_name=?;", -1, &debStmt, nil) == SQLITE_OK else {
            FusionLog.persist.error("rulestore remove debounce prepare fail")
            return rc == SQLITE_DONE
        }
        sqlite3_bind_text(debStmt, 1, name, -1, SQLITE_TRANSIENT)
        let delDeb = sqlite3_step(debStmt) == SQLITE_DONE
        sqlite3_finalize(debStmt)
        FusionLog.persist.info("rulestore remove \(name, privacy: .public) rc=\(rc == SQLITE_DONE) deb=\(delDeb)")
        return rc == SQLITE_DONE && delDeb
    }

    func loadDebounceState() -> [String: UInt64] {
        guard db != nil else { return [:] }
        var out: [String: UInt64] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT rule_name,last_fire_ts FROM debounce_state;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let ts = UInt64(sqlite3_column_int64(stmt, 1))
                out[name] = ts
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    func saveDebounceState(ruleName: String, lastFireTs: UInt64) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO debounce_state(rule_name,last_fire_ts,node_id) VALUES(?,?,?) ON CONFLICT(rule_name) DO UPDATE SET last_fire_ts=excluded.last_fire_ts,node_id=excluded.node_id;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, ruleName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(lastFireTs))
        sqlite3_bind_text(stmt, 3, nodeId, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE {
            FusionLog.persist.error("rulestore saveDebounceState step fail rc=\(rc) rule=\(ruleName, privacy: .public)")
        }
    }
}
