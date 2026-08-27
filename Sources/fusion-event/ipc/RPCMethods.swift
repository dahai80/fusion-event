import Foundation

actor RPCMethods {
    private let ruleEngine: RuleEngine
    private let eventLog: EventLog
    private let dispatcher: Dispatcher
    private let registry: SourceRegistry
    private let config: FusionEventConfig
    private let metrics: MetricsCollector
    private let version = "0.1.0-rc.1"
    private let schemaVersion = 1
    private let replayMaxLimit = 10_000
    private var startedAt: UInt64

    init(
        ruleEngine: RuleEngine,
        eventLog: EventLog,
        dispatcher: Dispatcher,
        registry: SourceRegistry,
        config: FusionEventConfig,
        metrics: MetricsCollector
    ) {
        self.ruleEngine = ruleEngine
        self.eventLog = eventLog
        self.dispatcher = dispatcher
        self.registry = registry
        self.config = config
        self.metrics = metrics
        self.startedAt = UInt64(Date().timeIntervalSince1970)
    }

    func dispatch(req: RPCRequest) async -> RPCResponse {
        switch req.method {
        case "ping":
            return ok(req, ["pong": true])
        case "event.health":
            return await health(req: req)
        case "event.shutdown":
            FusionLog.lifecycle.notice("event.shutdown RPC received, initiating graceful shutdown (D2)")
            LifecycleHandle.instance.requestShutdown()
            return ok(req, ["ok": true])
        case "rule.add":
            return await ruleAdd(req: req)
        case "rule.remove":
            return await ruleRemove(req: req)
        case "rule.list":
            return await ruleList(req: req)
        case "rule.reload":
            return await ruleReload(req: req)
        case "event.replay":
            return await replay(req: req)
        case "event.dry_run":
            return await dryRun(req: req)
        case "event.metrics":
            return await metricsRpc(req: req)
        case "event.subscribe":
            return ok(req, ["subscribed": true])
        case "event.pong":
            return ok(req, ["ok": true])
        default:
            return err(req, code: RPCErrorCode.methodNotFound.rawValue, message: "method not found: \(req.method)")
        }
    }

    private func health(req: RPCRequest) async -> RPCResponse {
        let now = UInt64(Date().timeIntervalSince1970)
        let stats = await dispatcher.stats()
        let dropped = await ruleEngine.dispatchDroppedCount()
        let src = await registry.health()
        return ok(req, [
            "ok": true,
            "version": version,
            "schema_version": schemaVersion,
            "uptime_sec": now - startedAt,
            "sources": src,
            "triggers": [
                "submitted": stats["submitted"] ?? 0,
                "blocked": stats["blocked"] ?? 0,
                "failed": stats["failed"] ?? 0,
                "dropped": stats["dropped"] ?? 0,
                "dispatch_dropped": dropped
            ] as [String: UInt64],
            "sock": config.sockPath,
            "node_id": config.nodeId
        ] as [String: Any])
    }

    private func ruleAdd(req: RPCRequest) async -> RPCResponse {
        guard let value = req.params?.value as? [String: Any] else {
            return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "missing params")
        }
        guard let name = value["rule_name"] as? String,
              name.count > 0, name.count <= 256,
              let typeStr = value["event_type"] as? String,
              let type = SystemEventType(rawValue: typeStr),
              let agent = value["target_agent"] as? String,
              agent.count > 0, agent.count <= 256 else {
            return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "invalid rule fields")
        }
        let pathPattern = value["path_pattern"] as? String
        if let pp = pathPattern {
            if pp.count > 4096 {
                return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "path_pattern too long (>4096) (S4)")
            }
            let badChars = pp.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }
            if !badChars.isEmpty {
                return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "path_pattern contains control chars (S4)")
            }
        }
        let rule = EventRule(
            ruleName: name,
            eventType: type,
            pathPattern: pathPattern,
            debounceMs: value["debounce_ms"] as? Int ?? 0,
            throttleMs: value["throttle_ms"] as? Int ?? 0,
            throttleMaxPerWindow: value["throttle_max_per_window"] as? Int ?? 1,
            targetAgent: agent,
            targetGraphId: value["target_graph_id"] as? String,
            enabled: value["enabled"] as? Bool ?? true,
            maxRetries: value["max_retries"] as? Int ?? 2,
            requireGuard: value["require_guard"] as? Bool ?? false
        )
        let added = await ruleEngine.addRule(rule)
        if added {
            FusionLog.lifecycle.notice("audit rule.add name=\(name, privacy: .public) type=\(type.rawValue) agent=\(agent, privacy: .public) guard=\(rule.requireGuard) (M4)")
        }
        return added ? ok(req, ["rule_name": name, "ok": true]) : err(req, code: RPCErrorCode.internalError.rawValue, message: "rule add fail")
    }

    private func ruleRemove(req: RPCRequest) async -> RPCResponse {
        guard let value = req.params?.value as? [String: Any],
              let name = value["rule_name"] as? String else {
            return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "missing rule_name")
        }
        let removed = await ruleEngine.removeRule(name)
        if removed {
            FusionLog.lifecycle.notice("audit rule.remove name=\(name, privacy: .public) (M4)")
        }
        return removed ? ok(req, ["ok": true]) : err(req, code: RPCErrorCode.internalError.rawValue, message: "rule remove fail")
    }

    private func ruleList(req: RPCRequest) async -> RPCResponse {
        let rules = await ruleEngine.allRules()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let rulesData = (try? enc.encode(rules)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return ok(req, ["rules": AnyCodable(rulesData)])
    }

    private func ruleReload(req: RPCRequest) async -> RPCResponse {
        await ruleEngine.reload()
        let count = await ruleEngine.allRules().count
        return ok(req, ["ok": true, "count": count])
    }

    private func replay(req: RPCRequest) async -> RPCResponse {
        guard let value = req.params?.value as? [String: Any] else {
            return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "missing params")
        }
        let sinceTs = UInt64((value["since_ts"] as? Int) ?? 0)
        let limit = min((value["limit"] as? Int) ?? 100, replayMaxLimit)
        let entries = await eventLog.replay(sinceTs: sinceTs, limit: limit)
        let enc = JSONEncoder()
        let data = (try? enc.encode(entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return ok(req, ["events": AnyCodable(data)])
    }

    private func dryRun(req: RPCRequest) async -> RPCResponse {
        guard let value = req.params?.value as? [String: Any] else {
            return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "missing params")
        }
        let sinceTs = UInt64((value["since_ts"] as? Int) ?? 0)
        let limit = min((value["limit"] as? Int) ?? 100, replayMaxLimit)
        let entries = await eventLog.replay(sinceTs: sinceTs, limit: limit)
        var out: [[String: AnyCodable]] = []
        for e in entries {
            let raw = RawEvent(
                sourceType: e.event.type,
                targetPath: e.event.targetPath,
                timestamp: e.event.timestamp,
                payload: e.event.payload,
                rawFlags: 0
            )
            let matched = await ruleEngine.dryRunMatch(raw)
            var triggers: [[String: String]] = []
            for rule in matched {
                let signal = Normalizer.normalize(event: raw, rule: rule, nodeId: config.nodeId)
                triggers.append([
                    "rule": rule.ruleName,
                    "trigger_id": signal.triggerId,
                    "idempotency_key": signal.idempotencyKey
                ])
            }
            out.append([
                "event": AnyCodable(e.event),
                "matched_rules": AnyCodable(matched.map { $0.ruleName }),
                "would_trigger": AnyCodable(!matched.isEmpty),
                "triggers": AnyCodable(triggers)
            ])
        }
        let enc = JSONEncoder()
        let data = (try? enc.encode(out)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return ok(req, ["events": AnyCodable(data)])
    }

    private func metricsRpc(req: RPCRequest) async -> RPCResponse {
        var snap = await metrics.snapshot()
        let src = await registry.health()
        var evCounts: [String: UInt64] = [:]
        if let srcDict = src as? [String: Any] {
            for (k, v) in srcDict {
                if let inner = v as? [String: Any], let total = inner["events_total"] as? UInt64 {
                    evCounts[k] = total
                }
            }
        }
        snap["source_events"] = AnyCodable(evCounts)
        return ok(req, ["ok": true, "metrics": AnyCodable(snap)])
    }

    private func ok(_ req: RPCRequest, _ result: [String: Any]) -> RPCResponse {
        RPCResponse(id: req.id, result: AnyCodable(result), error: nil)
    }

    private func ok(_ req: RPCRequest, _ result: [String: AnyCodable]) -> RPCResponse {
        RPCResponse(id: req.id, result: AnyCodable(result), error: nil)
    }

    private func err(_ req: RPCRequest, code: Int, message: String) -> RPCResponse {
        RPCResponse(id: req.id, result: nil, error: RPCError(code: code, message: message))
    }
}
