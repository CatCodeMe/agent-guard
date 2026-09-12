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

            Label("真实文件与网络监控尚未接入；现在可以用本地通知测试完整的用户决策流程。",
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
                        Text("待接入").font(.caption).foregroundStyle(.secondary)
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
            Text("“测试通知”只验证通知和用户选择；真实的文件拦截仍需 Endpoint Security 事件后端。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14)
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("通知测试记录").font(.headline)
            Text("目前仅显示本次运行中的测试事件。通知中的操作会回写到这里；不会采集真实应用活动或执行文件操作。")
                .font(.callout).foregroundStyle(.secondary)
            if store.previewEvents.isEmpty {
                empty("没有记录", detail: "在重点文件中点“测试通知”，然后在通知栏选择一个操作。", icon: "clock")
            } else {
                List(store.previewEvents) { event in
                    HStack {
                        Image(systemName: event.resolution == .pending ? "bell" : "checkmark.circle")
                            .foregroundStyle(event.resolution == .pending ? .indigo : .green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.ruleName)
                            Text("模拟事件 · 配置动作：\(event.action) · \(event.resolution.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }.padding(14)
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("配置与实际保护分开显示").font(.headline)
            capability("菜单栏与本地配置", detail: "可用", icon: "checkmark.circle")
            capability("macOS 本地通知测试", detail: "可用", icon: "bell.badge")
            capability("应用网络监控与阻断", detail: "未接入 Network Extension", icon: "circle.dashed")
            capability("敏感文件访问监控", detail: store.endpointSecurityState.label, icon: "circle.dashed")
            Text(store.endpointSecurityState.detail)
                .foregroundStyle(.secondary).font(.caption)
            Button("重新探测 Endpoint Security") { store.probeEndpointSecurity() }
            capability("HTTPS 敏感内容检查", detail: "未接入检查代理", icon: "circle.dashed")
            capability("受控启动隔离", detail: store.sandboxRuntimeStatus.label, icon: "circle.dashed")
            Text(store.sandboxRuntimeStatus.detail)
                .foregroundStyle(.secondary).font(.caption)
            Button("重新检测可选后端") { store.refreshSandboxRuntimeStatus() }
            Divider()
            Text("配置保存在本机，不上传云端。读取私钥与发送私钥是两类独立事件。")
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
