# 架构与能力边界

Agent Guard 是常驻 macOS 菜单栏的应用安全工具。用户选择需要保护的应用或 CLI 可执行文件，配置敏感文件及处理策略。桌面应用和 CLI 共享规则模型，但进程身份、辅助进程和子进程归属需要分别识别。

## 技术选择

首版采用 Swift、SwiftUI 和 Swift Package Manager，无第三方运行时依赖。菜单栏和系统安全接口均使用原生能力；未来跨平台时共享规则格式与行为约定，平台执行器独立实现。

Anthropic sandbox-runtime 使用 TypeScript，依赖 Node.js；macOS 后端使用 sandbox-exec，Linux 使用 bubblewrap。它通过 `srt --settings <file> <command>` 包装命令，适合在受控启动时约束命令及其后代，不应当作为接管任意已运行桌面应用的基础。当前 Agent Guard 只探测 PATH 中的 `srt`，不自动安装、启动或接管它；CLI 适配器会在确认上游命令参数和生命周期后再实现。

## 分层

1. SwiftUI：应用名单、敏感路径、策略、事件与保护状态；本地通知负责把待决事件交给用户。
2. GuardCore：可序列化配置与策略模型。目前的路径匹配仅用于配置预览。
3. 网络执行器（待实现）：评估 Network Extension，对网络流量按应用身份执行策略。
4. 文件执行器（最小真实闭环已接入）：建立 Endpoint Security 客户端并订阅 `AUTH_OPEN`。只有可执行文件与重点路径同时匹配时才生成审计事件；`record` 放行，`ask` 在内核 deadline 内等待通知动作，`block` 以 flags=0 拒绝。未匹配的事件以 `UInt32.max` 放行，不把整台机器变成默认阻断器。
5. 可选受控启动适配（已留接口）：只针对 Agent Guard 启动的 CLI；桌面应用仍依赖系统级身份与网络执行器。
6. 可选内容检测（待研究）：需要明文接入点，不能从普通 HTTPS 报文直接判断密钥泄露。

网络连接与文件打开是不同事件。访问私钥不等于外泄，向服务器连接也不证明发送了敏感内容。界面必须保留这种区别。

## 系统限制

- Endpoint Security 需要 Apple 授权 entitlement、合适的签名与部署方式，以及用户授予的系统权限。Network Extension 的资格与权限独立评估。
- 启动时会调用 `es_new_client` 并尝试订阅 `AUTH_OPEN`；失败原因会显示在能力状态页。默认 ad-hoc 开发包会因为 entitlement 或 TCC 不足而显示未启用。只有具备 Apple 授权 entitlement、合适签名并获完全磁盘访问权限时，系统才会交付可拦截事件。
- AUTH_OPEN 授权的是文件打开操作，不是每次读取的字节；应使用 flags 响应。FSEvents 不能代替文件读取授权。
- 授权事件具有截止时间，不能无限等待用户点击。真实实现必须定义超时策略；若先拒绝再询问，允许只影响后续重试，不能声称恢复已经失败的系统调用。
- 文件身份必须考虑符号链接、硬链接和重命名。当前首版使用 Endpoint Security 提供的绝对路径和保守的标准化匹配；这已经能做受控测试，但还不是 inode/file-id 级别的不可绕过身份。
- 应用身份首版按配置的可执行文件路径匹配；选择 `.app` 时覆盖其 `Contents/` 下的 helper。由 Agent 启动、但位于应用包外的任意 shell/CLI 子进程不会自动继承保护，必须单独添加其可执行文件，后续再做基于 audit token 的进程族归属。
- Network Extension 不会自动解密 TLS。复制报文适合观察，不能保证发送前阻断。
- GUI 退出、执行器崩溃、VPN 切换、事件丢失和已有连接都需要明确行为与测试，未完成前不能承诺全覆盖保护。

## 当前状态

当前代码实现本地配置、模拟策略预览、本地通知测试和最小的真实 `AUTH_OPEN` 执行器。点击规则旁的“测试通知”会生成一条明确标注的模拟事件；用户选择允许一次、阻止或打开应用后，事件状态会持久化到审计记录。真实事件只保存规则、应用、动作和结果；不读取或保存文件内容。网络仍未接入 Network Extension，默认 ad-hoc 包也不会宣称已经保护文件。

应用包现在带有独立的 `AppIcon.icns`，本地通知会使用 Agent Guard 图标；系统设置引导位于“能力状态”页。引导只负责打开 Full Disk Access 页面、在 Finder 中定位当前 bundle 和复制路径，用户仍需把正确的已签名 `.app` 拖入系统列表并打开开关。真实 Codex 验收先用受控 `agent-guard-open-probe` 验证授权链路，再让 Codex 打开同一个临时文件；若 Codex 的 helper 位于 `.app` 外部，需要把实际 helper 单独加入应用名单。

## 审计与统计

`audit.json` 保存最多 500 条元数据事件，按时间倒序写入。每条记录包含来源（模拟或 Endpoint Security）、事件类型、规则名、应用名、配置动作和最终结果。记录页从这些事件派生全部、阻止、允许一次、仅记录等计数；通知动作图标与结果区分显示。`ask` 超过授权 deadline 会记录“超时后阻止”，避免把已经拒绝的系统调用误报为用户允许。

## 官方依据

- [sandbox-runtime 源码与说明](https://github.com/anthropics/sandbox-runtime)
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [System Extensions](https://developer.apple.com/system-extensions/)
- [Endpoint Security entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.endpoint-security.client)
- [AUTH_OPEN](https://developer.apple.com/documentation/endpointsecurity/es_event_type_auth_open)
- [授权事件截止时间](https://developer.apple.com/documentation/endpointsecurity/es_message_t/deadline)
- [Network Extension 部署条件](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
