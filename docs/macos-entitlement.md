# macOS Endpoint Security 签名与特权部署

这份文档解释当前原型为什么不能在普通本地构建中完成真实阻断，以及拿到 Apple 条件后怎样复测。

## 两个独立门槛

1. `com.apple.developer.endpoint-security.client` 是 Apple 受限 entitlement。把 key 写进 `Resources/AgentGuard.entitlements` 只表示“申请签名时要求它”，不会自行获得授权。
2. Endpoint Security 客户端需要以 root 特权进程运行。菜单栏应用是用户进程，适合展示状态、发送通知和保存策略，不应直接承担 ES 客户端职责。生产结构是：

   ```text
   Agent Guard.app (用户会话 / SwiftUI)
          │ XPC 或受限 Unix socket
          ▼
   AgentGuardES (root LaunchDaemon + ES entitlement)
          │
          ▼
   Endpoint Security AUTH_OPEN
   ```

完全磁盘访问是第三个运行时门槛，属于 TCC 授权；它不能替代 Apple entitlement 或 root 部署。

## 本机当前状态

本机只有 Command Line Tools，没有 `/Applications/Xcode.app`，`security find-identity -v -p codesigning` 返回 `0 valid identities found`。因此当前构建脚本只能生成 ad-hoc 包：

```sh
bash scripts/build-app.sh
codesign -d --verbose=4 "build/Agent Guard.app"
codesign -d --entitlements :- "build/Agent Guard.app"
```

验收时应看到 ad-hoc、没有 TeamIdentifier；这类包不能代表已获得 Endpoint Security entitlement。

## 当前已实现的 helper seam

仓库现在包含独立的 `AgentGuardES` executable target。它已经把配置加载、应用/敏感路径匹配和 `AUTH_OPEN` flags 响应放到独立进程中，但还没有安装为 LaunchDaemon，也没有接上 UI IPC：

```sh
swift build -c release --product AgentGuardES
sudo .build/arm64-apple-macosx/release/AgentGuardES \
  --config "$HOME/Library/Application Support/AgentGuard/configuration.json" \
  --home "$HOME"
```

当前 `ask` 规则在 IPC 完成前会安全地按阻止处理；这用于验证特权执行器边界，不代表最终通知交互已经完成。

## 取得签名条件后

在装有完整 Xcode、已加入 Apple Developer Team 且 entitlement 已由 Apple 授权的机器上：

```sh
security find-identity -v -p codesigning
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" bash scripts/build-app.sh

codesign -d --verbose=4 "build/Agent Guard.app"
codesign -d --entitlements :- "build/Agent Guard.app"
codesign --verify --strict --verbose=2 "build/Agent Guard.app"
```

签名包应有 TeamIdentifier，且最终的特权 helper（不是只看 UI 包）应携带 `com.apple.developer.endpoint-security.client = true`。如果签名工具提示 profile 不允许该 entitlement，需要先在 Apple Developer 侧为 App ID/团队申请并生成相应 provisioning profile；不能靠 `codesign --entitlements` 绕过。

然后把实际运行 ES 客户端的 helper 或其签名 bundle 加入 **系统设置 → 隐私与安全性 → 完全磁盘访问权限**，重启 LaunchDaemon，再让菜单栏应用重新连接 IPC。当前 UI 中的“打开完全磁盘访问设置”按钮只负责打开页面，不能自动授予权限。

## 受控复测

先构建只读 probe：

```sh
bash scripts/build-open-probe.sh
printf 'agent-guard test\n' > /tmp/agent-guard-probe.txt
```

在 Agent Guard 中把 `build/agent-guard-open-probe` 加入受保护应用，把 `/tmp/agent-guard-probe.txt` 加入规则并选择“阻止”，再运行：

```sh
./build/agent-guard-open-probe /tmp/agent-guard-probe.txt
```

真实成功标准是 probe 返回 `Permission denied` 或 `Operation not permitted`，记录页出现来源为 `Endpoint Security` 的“已阻止”事件；选择“询问我”时，通知动作应决定一次放行或阻止。当前没有 root helper/有效 entitlement 时，probe 正常读出 1 byte 是预期结果，不能当作拦截失败或成功的证据。

Codex 验收要先通过 probe，再让 Codex 或它实际使用的 helper 打开同一个临时文件。若只添加 `.app` 没有事件，应把真正发起 `open(2)` 的包内 helper 或包外 CLI 单独加入应用名单。

## 官方依据

- [Apple：创建 Endpoint Security client](https://developer.apple.com/documentation/endpointsecurity/es_new_client%28_%3A_%3A%29?changes=la_1&language=ob_5)
- [Apple：Endpoint Security client](https://developer.apple.com/documentation/endpointsecurity/client)
- [Apple：Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
- [Apple：完全磁盘访问的官方说明](https://support.apple.com/en-ie/guide/security/secddd1d86a6/web)
