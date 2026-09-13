import AppKit
import Combine
import GuardCore

@MainActor
final class GuardStore: ObservableObject {
    @Published private(set) var configuration = GuardConfiguration()
    @Published private(set) var configurationError: String?
    @Published private(set) var notificationError: String?
    @Published private(set) var previewEvents: [PreviewEvent] = []
    @Published private(set) var sandboxRuntimeStatus = SandboxRuntimeProbe.current()
    @Published private(set) var endpointSecurityState: EndpointSecurityState = .notStarted
    private let endpointSecurityBackend = EndpointSecurityBackend()
    private let notificationCoordinator = NotificationCoordinator.shared
    let configurationURL: URL

    init(directory: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["AGENT_GUARD_DATA_DIR"]
        let base = directory ?? override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentGuard", isDirectory: true)
        configurationURL = base.appendingPathComponent("configuration.json")
        do { configuration = try ConfigurationFile.load(from: configurationURL) }
        catch {
            // Keep the broken/unreadable file untouched. A fresh in-memory
            // configuration still lets the user run the notification test and
            // repair persistence; the banner makes the persistence problem clear.
            configuration = .init()
            configurationError = "配置暂时无法读取：\(error.localizedDescription)。本次运行可以继续测试，但修改可能无法持久化。"
        }
        notificationCoordinator.onAction = { [weak self] eventID, action in
            self?.resolvePreviewEvent(eventID, action: action)
        }
        notificationCoordinator.onError = { [weak self] message in
            self?.notificationError = message
        }
        probeEndpointSecurity()
    }

    var canEdit: Bool { true }

    private func update(_ transform: (inout GuardConfiguration) -> Void) {
        guard canEdit else { return }
        var next = configuration
        transform(&next)
        do {
            try ConfigurationFile.save(next, to: configurationURL)
            configuration = next
            configurationError = nil
        } catch {
            // Preserve the in-memory change so notification and policy previews
            // remain usable even when macOS temporarily denies persistence.
            configuration = next
            configurationError = "配置未能保存：\(error.localizedDescription)。当前修改仅保留在本次运行。"
        }
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

    func probeEndpointSecurity() {
        endpointSecurityBackend.probe()
        endpointSecurityState = endpointSecurityBackend.state
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

    func testNotification(_ rule: SensitivePathRule) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let decision = PolicyPreview.evaluate(path: rule.path, rules: configuration.rules, homeDirectory: home)
        let eventID = UUID()
        let action = decision?.action.label ?? "没有启用的匹配规则"
        previewEvents.insert(.init(id: eventID, date: Date(), ruleName: rule.name, action: action), at: 0)
        previewEvents = Array(previewEvents.prefix(50))
        notificationError = nil
        notificationCoordinator.sendTestEvent(id: eventID, ruleName: rule.name, configuredAction: action)
    }

    private func resolvePreviewEvent(_ id: UUID, action: NotificationAction) {
        guard let index = previewEvents.firstIndex(where: { $0.id == id }) else { return }
        previewEvents[index].resolution = PreviewResolution(action)
    }
}

enum PreviewResolution: String {
    case pending
    case allowedOnce
    case blocked
    case opened

    init(_ action: NotificationAction) {
        switch action {
        case .allowOnce: self = .allowedOnce
        case .block: self = .blocked
        case .open: self = .opened
        }
    }

    var label: String {
        switch self {
        case .pending: return "等待用户操作"
        case .allowedOnce: return "用户选择允许一次"
        case .blocked: return "用户选择阻止"
        case .opened: return "用户打开 Agent Guard"
        }
    }
}

struct PreviewEvent: Identifiable {
    let id: UUID
    let date: Date
    let ruleName: String
    let action: String
    var resolution: PreviewResolution = .pending
}
