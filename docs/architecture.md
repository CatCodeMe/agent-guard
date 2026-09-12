# 架构与能力边界

Agent Guard 是常驻 macOS 菜单栏的应用安全工具。用户选择需要保护的应用或 CLI 可执行文件，配置敏感文件及处理策略。桌面应用和 CLI 共享规则模型，但进程身份、辅助进程和子进程归属需要分别识别。

## 技术选择

首版采用 Swift、SwiftUI 和 Swift Package Manager，无第三方运行时依赖。菜单栏和系统安全接口均使用原生能力；未来跨平台时共享规则格式与行为约定，平台执行器独立实现。

Anthropic sandbox-runtime 使用 TypeScript，依赖 Node.js；macOS 后端使用 sandbox-exec，Linux 使用 bubblewrap。它通过 `srt --settings <file> <command>` 包装命令，适合在受控启动时约束命令及其后代，不应当作为接管任意已运行桌面应用的基础。当前 Agent Guard 只探测 PATH 中的 `srt`，不自动安装、启动或接管它；CLI 适配器会在确认上游命令参数和生命周期后再实现。

## 分层

1. SwiftUI：应用名单、敏感路径、策略、事件与保护状态。
2. GuardCore：可序列化配置与策略模型。目前的路径匹配仅用于配置预览。
3. 网络执行器（待实现）：评估 Network Extension，对网络流量按应用身份执行策略。
4. 文件执行器（待实现）：评估 Endpoint Security，对敏感文件打开请求做授权和记录。
5. 可选受控启动适配（已留接口）：只针对 Agent Guard 启动的 CLI；桌面应用仍依赖系统级身份与网络执行器。
6. 可选内容检测（待研究）：需要明文接入点，不能从普通 HTTPS 报文直接判断密钥泄露。

网络连接与文件打开是不同事件。访问私钥不等于外泄，向服务器连接也不证明发送了敏感内容。界面必须保留这种区别。

## 系统限制

- Endpoint Security 需要 Apple 授权 entitlement、合适的签名与部署方式，以及用户授予的系统权限。Network Extension 的资格与权限独立评估。
- AUTH_OPEN 授权的是文件打开操作，不是每次读取的字节；应使用 flags 响应。FSEvents 不能代替文件读取授权。
- 授权事件具有截止时间，不能无限等待用户点击。真实实现必须定义超时策略；若先拒绝再询问，允许只影响后续重试，不能声称恢复已经失败的系统调用。
- 文件身份必须考虑符号链接、硬链接和重命名。当前字符串路径预览不能直接作为安全边界。
- Network Extension 不会自动解密 TLS。复制报文适合观察，不能保证发送前阻断。
- GUI 退出、执行器崩溃、VPN 切换、事件丢失和已有连接都需要明确行为与测试，未完成前不能承诺全覆盖保护。

## 当前状态

当前代码仅实现本地配置和模拟策略预览，没有安装系统扩展，没有监听文件访问，没有阻断网络。日志预览仅存内存，配置只保存应用与路径规则，不读取敏感文件内容。

## 官方依据

- [sandbox-runtime 源码与说明](https://github.com/anthropics/sandbox-runtime)
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [System Extensions](https://developer.apple.com/system-extensions/)
- [Endpoint Security entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.endpoint-security.client)
- [AUTH_OPEN](https://developer.apple.com/documentation/endpointsecurity/es_event_type_auth_open)
- [授权事件截止时间](https://developer.apple.com/documentation/endpointsecurity/es_message_t/deadline)
- [Network Extension 部署条件](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
