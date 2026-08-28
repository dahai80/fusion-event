# fusion-event 发布签名清单 (逐步)

商用发布前置: codesign + notarize。当前 keychain 无 Developer ID 证书, 无 notarytool profile。
本清单逐项可验证。每步完成后我 (Claude) 可核 keychain/签名状态。

## 阶段 1 — 获取凭据 (Apple Developer 后台 + 本地 keychain)

### 1.1 创建 Developer ID Application 证书

仅一次。在 Apple Developer 后台签发, 装入登录钥匙串。

1. 打开 https://developer.apple.com/account/resources/certificates/list
2. 点 "+" → 选 "Developer ID Application" → 继续
3. 按提示用本地 CSR (证书签名请求)。生成 CSR:
   ```bash
   # 钥匙串访问 → 证书助理 → 从证书颁发机构请求证书 → 填邮箱 → 存到磁盘 → 得 CertificateSigningRequest.certSigningRequest
   ```
   或命令行 (更可控):
   ```bash
   # 在 ! 提示符里跑 (交互式):
   ! security csreqgen -r "internal" -o /tmp/fusion-event.csr   # 仅示意, 实际用钥匙串访问生成更稳
   ```
4. 上传 CSR → 下载 `developerID_application.cer`
5. 双击 .cer 装入登录钥匙串
6. **验证** (我可跑):
   ```bash
   security find-identity -v -p codesigning
   # 期望: "Developer ID Application: <你的名> (<TEAMID>)" 出现在 valid identities
   ```

### 1.2 记下 TEAMID + 证书确切名

```bash
# 完成后我跑这行取确切名 (sign.sh 的 DEVELOPER_ID_NAME 要用它):
security find-identity -v -p codesigning | rg "Developer ID Application"
```

### 1.3 创建 App-specific password (notarytool 用)

1. 打开 https://appleid.apple.com → 登录 → "App 专用密码" → 生成
2. 记下密码 (仅显示一次)
3. 存入 keychain (notarytool profile):
   ```bash
   # 在 ! 提示符跑 (交互输入 Apple ID 密码确认):
   ! xcrun notarytool store-credentials "fusion-event-notary" \
       --apple-id "<你的Apple ID邮箱>" \
       --team-id "<TEAMID>" \
       --password "<app-specific-password>"
   ```
4. **验证** (我可跑):
   ```bash
   xcrun notarytool history --keychain-profile "fusion-event-notary"
   # 期望: 不报 "No Keychain password item found"
   ```

## 阶段 2 — 签名 + 公证 (我跑 sign.sh)

凭据齐后, 一步到位:

```bash
# 确切名替换 REPLACE_ME (从 1.2 取):
DEVELOPER_ID_NAME="Developer ID Application: <你的名> (<TEAMID>)" \
./scripts/sign.sh
```

sign.sh 自动: release build → codesign (hardened runtime + timestamp + entitlements) → 验签 → notarize (zip+submit+wait) → staple → validate。

**验证产物** (我可跑):
```bash
codesign --verify --strict --verbose=2 .build/release/fusion-event
spctl --assess --type execute --verbose .build/release/fusion-event   # 公证+staple 后应 pass
```

## 阶段 3 — (可选, ES 批准后) EndpointSecurity entitlement

当前 `com.apple.developer.endpoint-security.client` 在 entitlements 里注释 (blocked on Apple 审批)。
Apple 批准后:
1. 删 `scripts/fusion-event.entitlements` 里 ES entitlement 的注释
2. 重跑 sign.sh (需新 provisioning profile 含 ES entitlement)
3. daemon 启用 ES 源 (Config `esEnabled=true`)

## 状态跟踪

| 项 | 状态 |
|----|------|
| Developer ID Application 证书 | ❌ 缺 (keychain 0 identities) |
| TEAMID | ❌ 未取 |
| notarytool profile | ❌ 缺 |
| sign.sh 实跑 | ❌ 未跑 |
| ES entitlement | ❌ 待 Apple 审批 |

每完成一项告诉我, 我核状态 + 更新此表。

## 上下游集成对接状态 (PRD + union 架构)

PRD/架构要求 4 个集成点。全部源码坐实 + issue 推进上游:

| 集成点 | 方向 | issue | 状态 | 残留 |
|--------|------|-------|------|------|
| task.submit | 下游 → fusion-agent-studio | agent-studio #250 CLOSED | rc.2 已对齐: `input.event` snake_case 匹配 `trigger_input.py` 冻结契约; E2E 已验 (M9) | 无 |
| guard.audit | 上游 ← fusion-guard | fusion-guard #3 CLOSED | rc.4 已对齐 + 真实 E2E 验证: 方向 A, 上游 v0.1.1 实现 D-10 冻结契约 (`guard.audit` + `AuditDecision`); fusion-event 调 audit 传 trigger_id/event_type/target_path/target_agent/payload/node_id/tenant_id; **tenant_id 必须为 `"default"`** (guard 将本地 daemon 身份 uid 绑定 `fg_store::DEFAULT_TENANT`, 其它值 → 跨租户拒绝 -32001 → fail-closed); `E2EGuardTests.swift` 真实 daemon pass (benign) + block (rm-rf 注入) 全通过 | 无 |
| memory.retrieve_context | 上游 ← fusion-memory | fusion-memory #4 CLOSED | rc.3 已对齐 + 真实 E2E 验证: 上游加 `memory.retrieve_context_contract` (method/params/response 全匹配); socket 路径 fusion-event 适配 `~/.fusion-memory/fusion-memory.sock`; `E2EMemoryTests.swift` 真实 daemon commit+retrieve+delete_scope 全通过 | 无 |
| event.subscribe / event.notification | 下游 → fusion-studio (消费方) | fusion-studio #346 OPEN | 新提, 消费方未实现 | studio 需加 EventBridge UDS 长连 + NDJSON 推流解析; fusion-event 侧已实现 push (camelCase, PRD 契约) |

issue 链接:
- task.submit: https://github.com/dahai80/fusion-agent-studio/issues/250
- guard.audit: https://github.com/dahai80/fusion-guard/issues/3
- memory.retrieve_context: https://github.com/dahai80/fusion-memory/issues/4
- event.subscribe: https://github.com/dahai80/fusion-studio/issues/346

task.submit、guard、memory 三链均 E2E 真实 daemon 验过 (rc.4)。studio 消费方待 studio 侧实现 (issue #346 OPEN)。商用发布前硬阻塞: ES 签名凭据 (issue #1) + studio 消费方。
