import AppKit
import Combine
import GuardCore

@MainActor
final class GuardStore: ObservableObject {
    @Published private(set) var configuration = GuardConfiguration()
    @Published private(set) var configurationError: String?
    @Published private(set) var previewEvents: [PreviewEvent] = []
    @Published private(set) var sandboxRuntimeStatus = SandboxRuntimeProbe.current()
    private var loadFailed = false
    let configurationURL: URL

    init(directory: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["AGENT_GUARD_DATA_DIR"]
        let base = directory ?? override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentGuard", isDirectory: true)
        configurationURL = base.appendingPathComponent("configuration.json")
        do { configuration = try ConfigurationFile.load(from: configurationURL) }
        catch {
            loadFailed = true
            configurationError = error.localizedDescription
        }
    }

    var canEdit: Bool { !loadFailed }

    private func update(_ transform: (inout GuardConfiguration) -> Void) {
        guard canEdit else { return }
        var next = configuration
        transform(&next)
        do {
            try ConfigurationFile.save(next, to: configurationURL)
            configuration = next
            configurationError = nil
        } catch { configurationError = error.localizedDescription }
    }

    func addApplication(_ url: URL) {
        addApplication(url, agentKind: nil)
    }

    private func addApplication(_ url: URL, agentKind: AgentKind?) {
        let isApp = url.pathExtension.lowercased() == "app"
        guard isApp || FileManager.default.isExecutableFile(atPath: url.path) else {
            configurationError = "请选择 .app 应用或可执行文件。"
            return
        }
        let bundle = isApp ? Bundle(url: url) : nil
        guard !isApp || bundle?.executableURL != nil else {
            configurationError = "所选应用没有可识别的可执行文件。"
            return
        }
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        update {
            guard !$0.applications.contains(where: { $0.path == url.path }) else { return }
            $0.applications.append(.init(
                name: name, path: url.path, bundleIdentifier: bundle?.bundleIdentifier,
                agentKind: agentKind
            ))
        }
    }

    func discoverCommonAgents() {
        var found = 0
        for preset in AgentCatalog.common {
            for candidate in preset.candidatePaths {
                let url = URL(fileURLWithPath: candidate)
                let isApp = url.pathExtension.lowercased() == "app"
                let exists = isApp
                    ? Bundle(url: url)?.executableURL != nil
                    : FileManager.default.isExecutableFile(atPath: candidate)
                guard exists else { continue }
                let wasPresent = configuration.applications.contains { $0.path == candidate }
                addApplication(url, agentKind: preset.kind)
                if !wasPresent { found += 1 }
                break
            }
        }
        if found == 0 {
            configurationError = "没有在常见安装路径找到新的 Agent；也可以手动添加应用或 CLI。"
        }
    }

    func refreshSandboxRuntimeStatus() {
        sandboxRuntimeStatus = SandboxRuntimeProbe.current()
    }

    func addRule(_ rule: SensitivePathRule) {
        update {
            guard !$0.rules.contains(where: { $0.path == rule.path && $0.scope == rule.scope }) else { return }
            $0.rules.append(rule)
        }
    }

    func addSuggestedRules() {
        update { configuration in
            for rule in GuardConfiguration.suggestedRules
            where !configuration.rules.contains(where: { $0.path == rule.path }) {
                configuration.rules.append(rule)
            }
        }
    }

    func removeApplication(_ id: UUID) { update { $0.applications.removeAll { $0.id == id } } }
    func removeRule(_ id: UUID) { update { $0.rules.removeAll { $0.id == id } } }
    func changeAction(_ id: UUID, to action: RuleAction) {
        update {
            guard let index = $0.rules.firstIndex(where: { $0.id == id }) else { return }
            $0.rules[index].action = action
        }
    }
    func setEnabled(_ id: UUID, to enabled: Bool) {
        update {
            guard let index = $0.rules.firstIndex(where: { $0.id == id }) else { return }
            $0.rules[index].enabled = enabled
        }
    }

    func preview(_ rule: SensitivePathRule) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let decision = PolicyPreview.evaluate(path: rule.path, rules: configuration.rules, homeDirectory: home)
        previewEvents.insert(.init(
            id: UUID(), date: Date(), ruleName: rule.name,
            action: decision?.action.label ?? "没有启用的匹配规则"
        ), at: 0)
        previewEvents = Array(previewEvents.prefix(50))
    }
}

struct PreviewEvent: Identifiable {
    let id: UUID
    let date: Date
    let ruleName: String
    let action: String
}
