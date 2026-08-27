import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)

actor RuleStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    private let dbPath: String
    private let nodeId: String

    init(dbPath: String, nodeId: String) {
        self.dbPath = dbPath
        self.nodeId = nodeId
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var handle: OpaquePointer? = nil
        if sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            FusionLog.persist.error("rulestore open fail \(msg, privacy: .public)")
            self.db = handle
            return
        }
        self.db = handle
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        let ddl = """
        CREATE TABLE IF NOT EXISTS rules (
            rule_name      TEXT PRIMARY KEY,
            event_type     TEXT NOT NULL,
            path_pattern   TEXT,
            debounce_ms    INTEGER DEFAULT 0,
            throttle_ms    INTEGER DEFAULT 0,
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
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    func loadAll() -> [EventRule] {
        guard db != nil else { return [] }
        var rules: [EventRule] = []
        var stmt: OpaquePointer?
        let sql = "SELECT rule_name,event_type,path_pattern,debounce_ms,throttle_ms,target_agent,target_graph_id,enabled,max_retries,require_guard FROM rules;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let type = String(cString: sqlite3_column_text(stmt, 1))
                let pathCol = sqlite3_column_text(stmt, 2)
                let path = pathCol == nil ? nil : String(cString: pathCol!)
                let deb = sqlite3_column_int(stmt, 3)
                let thr = sqlite3_column_int(stmt, 4)
                let agent = String(cString: sqlite3_column_text(stmt, 5))
                let graphCol = sqlite3_column_text(stmt, 6)
                let graph = graphCol == nil ? nil : String(cString: graphCol!)
                let en = sqlite3_column_int(stmt, 7) != 0
                let mr = sqlite3_column_int(stmt, 8)
                let rg = sqlite3_column_int(stmt, 9) != 0
                guard let et = SystemEventType(rawValue: type) else { continue }
                rules.append(EventRule(
                    ruleName: name, eventType: et, pathPattern: path,
                    debounceMs: Int(deb), throttleMs: Int(thr),
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
        INSERT INTO rules(rule_name,event_type,path_pattern,debounce_ms,throttle_ms,target_agent,target_graph_id,enabled,max_retries,require_guard,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(rule_name) DO UPDATE SET
            event_type=excluded.event_type,path_pattern=excluded.path_pattern,
            debounce_ms=excluded.debounce_ms,throttle_ms=excluded.throttle_ms,
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
        sqlite3_bind_text(stmt, 6, rule.targetAgent, -1, SQLITE_TRANSIENT)
        if let g = rule.targetGraphId, !g.isEmpty { sqlite3_bind_text(stmt, 7, g, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_text(stmt, 7, "", -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 8, rule.enabled ? 1 : 0)
        sqlite3_bind_int(stmt, 9, Int32(rule.maxRetries))
        sqlite3_bind_int(stmt, 10, rule.requireGuard ? 1 : 0)
        sqlite3_bind_double(stmt, 11, now)
        sqlite3_bind_double(stmt, 12, now)
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
        sqlite3_prepare_v2(db, "DELETE FROM rules WHERE rule_name=?;", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        let delDeb = sqlite3_exec(db, "DELETE FROM debounce_state WHERE rule_name='\(escape(name))';", nil, nil, nil) == SQLITE_OK
        FusionLog.persist.info("rulestore remove \(name, privacy: .public) rc=\(rc == SQLITE_DONE)")
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
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}
