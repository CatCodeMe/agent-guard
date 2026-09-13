import AppKit
import GuardCore
import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationView: View {
    @ObservedObject var store: GuardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 32)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Guard").font(.title2.bold())
                    Text("选择关注的应用与文件，让每一次决定都有依据。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("开发预览").font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }.padding(24)

            Label("文件访问后端已接入 AUTH_OPEN；是否能真正拦截取决于 Endpoint Security entitlement、签名和完全磁盘访问权限。现在仍可先用本地通知测试用户决策流程。",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.indigo.opacity(0.06))

            if let error = store.configurationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding(.horizontal, 24).padding(.top, 12)
            }
            if let error = store.notificationError {
                Label(error, systemImage: "bell.badge")
                    .foregroundStyle(.orange).padding(.horizontal, 24).padding(.top, 8)
            }
            if let error = store.auditError {
                Label(error, systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange).padding(.horizontal, 24).padding(.top, 8)
            }

            TabView {
                applications.tabItem { Label("应用", systemImage: "app.badge") }
                rules.tabItem { Label("重点文件", systemImage: "doc.badge.gearshape") }
                events.tabItem { Label("记录", systemImage: "clock") }
                capabilities.tabItem { Label("能力状态", systemImage: "slider.horizontal.3") }
            }.padding(20)
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("关注的应用").font(.headline)
                Spacer()
                Button("识别常见 Agent") { store.discoverCommonAgents() }
                Button("添加应用或 CLI…", action: chooseApplication).disabled(!store.canEdit)
            }
            Text("识别只检查常见安装路径，不会启动或修改 Codex、Claude、Cursor 等应用；添加成功也不代表已经启用保护。")
                .font(.callout).foregroundStyle(.secondary)
            if store.configuration.applications.isEmpty {
                empty("添加第一个应用", detail: "选择 .app 或 CLI 可执行文件。不会启动或修改所选应用。", icon: "app.dashed")
            } else {
                List(store.configuration.applications) { app in
                    HStack {
                        Image(systemName: app.bundleIdentifier == nil ? "terminal" : "app")
                            .foregroundStyle(.indigo).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.body.weight(.medium))
                            Text("\(app.agentKind?.label ?? AgentKind.custom.label) · \(app.path)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text("保护候选").font(.caption).foregroundStyle(.secondary)
                        Button { store.removeApplication(app.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("从配置中移除，不会删除应用").disabled(!store.canEdit)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }.padding(14)
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("重点文件").font(.headline)
                Spacer()
                Button("添加常见规则") { store.addSuggestedRules() }.disabled(!store.canEdit)
                Button("选择文件或目录…", action: choosePath).disabled(!store.canEdit)
            }
            Text("常见规则包含 SSH 私钥与 AWS 凭据路径。这里只保存路径，不读取文件内容。")
                .font(.callout).foregroundStyle(.secondary)
            if store.configuration.rules.isEmpty {
                empty("还没有文件规则", detail: "可以从常见规则开始，也可以指定自己的敏感文件。", icon: "doc.text.magnifyingglass")
            } else {
                List(store.configuration.rules) { rule in
                    HStack(spacing: 12) {
                        Toggle("启用规则", isOn: Binding(
                            get: { rule.enabled }, set: { store.setEnabled(rule.id, to: $0) }
                        )).labelsHidden().disabled(!store.canEdit)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name).font(.body.weight(.medium))
                            Text("\(rule.path) · \(rule.scope.label)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Label(rule.action.label, systemImage: rule.action.iconName)
                            .font(.caption).foregroundStyle(actionColor(rule.action))
                        Picker("处理方式", selection: Binding(
                            get: { rule.action }, set: { store.changeAction(rule.id, to: $0) }
                        )) {
                            ForEach(RuleAction.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().frame(width: 100).disabled(!store.canEdit)
                        Button("测试通知") { store.testNotification(rule) }
                            .help("发送带操作按钮的本地测试通知，不会访问或阻止文件")
                        Button { store.removeRule(rule.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("仅移除规则，不会删除文件").disabled(!store.canEdit)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
            Text("“测试通知”不会访问文件；真实拦截只对同时匹配受保护应用和重点文件的 AUTH_OPEN 事件生效。开发包若显示未启用，请先使用具备 entitlement 的签名包并授予完全磁盘访问权限。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14)
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("记录与统计").font(.headline)
            Text("记录只保存规则、应用、动作和结果，不保存文件内容或通知正文。测试事件与真实 Endpoint Security 事件会分开标记。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                statCard("全部", value: store.auditStatistics.total, icon: "list.bullet.rectangle")
                statCard("已阻止", value: store.auditStatistics.blocked + store.auditStatistics.timedOut, icon: "hand.raised.fill")
                statCard("已允许", value: store.auditStatistics.allowedOnce, icon: "checkmark.circle.fill")
                statCard("仅记录", value: store.auditStatistics.recorded, icon: "eye")
            }
            if store.auditEvents.isEmpty {
                empty("没有记录", detail: "在重点文件中点“测试通知”，然后在通知栏选择一个操作。", icon: "clock")
            } else {
                List(store.auditEvents) { event in
                    HStack {
                        Image(systemName: event.outcome.iconName)
                            .foregroundStyle(outcomeColor(event.outcome))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.ruleName)
                            Text("\(event.source.label) · \(event.kind.label) · 配置动作：\(event.configuredAction.label) · \(event.outcome.label)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let applicationName = event.applicationName {
                                Text("应用：\(applicationName)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }.padding(14)
    }

    private func statCard(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title3.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private func outcomeColor(_ outcome: AuditOutcome) -> Color {
        switch outcome {
        case .pending: .indigo
        case .recorded: .secondary
        case .allowedOnce: .green
        case .blocked, .timedOut: .red
        case .opened: .orange
        }
    }

    private func actionColor(_ action: RuleAction) -> Color {
        switch action {
        case .record: .secondary
        case .ask: .orange
        case .block: .red
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("配置与实际保护分开显示").font(.headline)
            capability("菜单栏与本地配置", detail: "可用", icon: "checkmark.circle")
            capability("macOS 本地通知测试", detail: "可用", icon: "bell.badge")
            capability("应用网络监控与阻断", detail: "未接入 Network Extension", icon: "circle.dashed")
            capability("敏感文件访问监控", detail: store.endpointSecurityState.label, icon: store.endpointSecurityState == .available ? "checkmark.shield" : "circle.dashed")
            Text(store.endpointSecurityState.detail)
                .foregroundStyle(.secondary).font(.caption)
            HStack(spacing: 10) {
                Button("打开完全磁盘访问设置") { store.openFullDiskAccessSettings() }
                Button("在 Finder 中显示 Agent Guard") { store.revealCurrentApplication() }
                Button("复制应用路径") { store.copyCurrentApplicationPath() }
                    .help("将当前签名的 Agent Guard.app 路径复制到剪贴板")
            }
            Text("真实启用分两层：Endpoint Security 客户端需要 Apple 授权的 entitlement、合适签名和 root 特权 LaunchDaemon；菜单栏应用本身只负责配置、通知和控制。特权 helper 还需要获得完全磁盘访问权限。当前本地 ad-hoc 包和直连 UI 后端只能运行模拟通知，不能获得系统拦截权限。")
                .foregroundStyle(.secondary).font(.caption)
            HStack {
                Button("重新探测 Endpoint Security") { store.probeEndpointSecurity() }
                if store.endpointSecurityState == .available {
                    Label("实时授权后端已连接", systemImage: "checkmark.shield.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            capability("HTTPS 敏感内容检查", detail: "未接入检查代理", icon: "circle.dashed")
            capability("受控启动隔离", detail: store.sandboxRuntimeStatus.label, icon: "circle.dashed")
            Text(store.sandboxRuntimeStatus.detail)
                .foregroundStyle(.secondary).font(.caption)
            Button("重新检测可选后端") { store.refreshSandboxRuntimeStatus() }
            Divider()
            Text("配置和审计记录保存在本机，不上传云端。读取敏感文件与把内容发送到网络是两类独立事件。")
                .foregroundStyle(.secondary).font(.callout)
            Spacer()
        }.padding(18)
    }

    private func capability(_ title: String, detail: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.callout)
        }
    }

    private func empty(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "添加关注的应用或 CLI"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { store.addApplication(url) }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.title = "选择重点关注的文件或目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            store.addRule(.init(
                name: url.lastPathComponent, path: url.path,
                scope: isDirectory.boolValue ? .directory : .file
            ))
        }
    }
}
