import Foundation

actor RPCMethods {
    private let ruleEngine: RuleEngine
    private let eventLog: EventLog
    private let dispatcher: Dispatcher
    private let registry: SourceRegistry
    private let config: FusionEventConfig
    private let version = "0.1.0"
    private let schemaVersion = 1
    private var startedAt: UInt64

    init(
        ruleEngine: RuleEngine,
        eventLog: EventLog,
        dispatcher: Dispatcher,
        registry: SourceRegistry,
        config: FusionEventConfig
    ) {
        self.ruleEngine = ruleEngine
        self.eventLog = eventLog
        self.dispatcher = dispatcher
        self.registry = registry
        self.config = config
        self.startedAt = UInt64(Date().timeIntervalSince1970)
    }

    func dispatch(req: RPCRequest) async -> RPCResponse {
        switch req.method {
        case "ping":
            return ok(req, ["pong": true])
        case "event.health":
            return await health(req: req)
        case "event.shutdown":
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
                "failed": stats["failed"] ?? 0
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
              let typeStr = value["event_type"] as? String,
              let type = SystemEventType(rawValue: typeStr),
              let agent = value["target_agent"] as? String else {
            return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "invalid rule fields")
        }
        let rule = EventRule(
            ruleName: name,
            eventType: type,
            pathPattern: value["path_pattern"] as? String,
            debounceMs: value["debounce_ms"] as? Int ?? 0,
            throttleMs: value["throttle_ms"] as? Int ?? 0,
            targetAgent: agent,
            targetGraphId: value["target_graph_id"] as? String,
            enabled: value["enabled"] as? Bool ?? true,
            maxRetries: value["max_retries"] as? Int ?? 2,
            requireGuard: value["require_guard"] as? Bool ?? false
        )
        let added = await ruleEngine.addRule(rule)
        return added ? ok(req, ["rule_name": name, "ok": true]) : err(req, code: RPCErrorCode.internalError.rawValue, message: "rule add fail")
    }

    private func ruleRemove(req: RPCRequest) async -> RPCResponse {
        guard let value = req.params?.value as? [String: Any],
              let name = value["rule_name"] as? String else {
            return err(req, code: RPCErrorCode.ruleValidation.rawValue, message: "missing rule_name")
        }
        let removed = await ruleEngine.removeRule(name)
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
        let limit = (value["limit"] as? Int) ?? 100
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
        let limit = (value["limit"] as? Int) ?? 100
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
