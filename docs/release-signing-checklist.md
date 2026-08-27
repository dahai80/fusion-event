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

## 联调 issue 推进状态 (c)

三链契约 drift 全部源码坐实 + comment 推进上游:

| 链 | issue | drift | comment |
|----|-------|-------|---------|
| task.submit | agent-studio #250 | input event 字段名 (camelCase vs snake_case) | https://github.com/dahai80/fusion-agent-studio/issues/250#issuecomment-5436582134 |
| guard.audit | fusion-guard #3 | 方法名 (`guard.audit` 不存在, `guard.evaluate` 语义错位: 内容审计 vs 事件门禁) + response 形状 | https://github.com/dahai80/fusion-guard/issues/3#issuecomment-5437537670 + socket 自答 https://github.com/dahai80/fusion-guard/issues/3#issuecomment-5437542813 |
| memory.retrieve_context | fusion-memory #4 | 4 处 drift: 方法名 + 参数名 + response 结构 + socket 路径 (`/tmp/` vs `~/.fusion-memory/`) | https://github.com/dahai80/fusion-memory/issues/4#issuecomment-5436646138 + socket 自答 https://github.com/dahai80/fusion-memory/issues/4#issuecomment-5437549792 |

guard/memory 两链当前 happy-path 不通 (guard 方法不存在, memory 方法名/路径 drift)。task.submit 唯一成熟链, E2E 已验 (M9)。商用发布前等上游响应决定方向 (A 上游改 vs B fusion-event 改)。
