import AppKit
import Combine
import GuardCore

@MainActor
final class GuardStore: ObservableObject {
    @Published private(set) var configuration = GuardConfiguration()
    @Published private(set) var configurationError: String?
    @Published private(set) var auditError: String?
    @Published private(set) var notificationError: String?
    @Published private(set) var auditEvents: [AuditEvent] = []
    @Published private(set) var sandboxRuntimeStatus = SandboxRuntimeProbe.current()
    @Published private(set) var endpointSecurityState: EndpointSecurityState = .notStarted
    private let endpointSecurityBackend = EndpointSecurityBackend()
    private let notificationCoordinator = NotificationCoordinator.shared
    let configurationURL: URL
    let auditURL: URL

    init(directory: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["AGENT_GUARD_DATA_DIR"]
        let base = directory ?? override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentGuard", isDirectory: true)
        configurationURL = base.appendingPathComponent("configuration.json")
        auditURL = base.appendingPathComponent("audit.json")
        do { configuration = try ConfigurationFile.load(from: configurationURL) }
        catch {
            // Keep the broken/unreadable file untouched. A fresh in-memory
            // configuration still lets the user run the notification test and
            // repair persistence; the banner makes the persistence problem clear.
            configuration = .init()
            configurationError = "配置暂时无法读取：\(error.localizedDescription)。本次运行可以继续测试，但修改可能无法持久化。"
        }
        do { auditEvents = try AuditFile.load(from: auditURL) }
        catch {
            auditError = "审计记录暂时无法读取：\(error.localizedDescription)。新的记录仍会保留在本次运行中。"
        }
        endpointSecurityBackend.onMatched = { [weak self] request in
            self?.handleEndpointMatch(request)
        }
        endpointSecurityBackend.onDecision = { [weak self] decision in
            self?.handleEndpointDecision(decision)
        }
        endpointSecurityBackend.updateConfiguration(configuration)
        notificationCoordinator.onAction = { [weak self] eventID, action in
            self?.resolveNotification(eventID, action: action)
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
            endpointSecurityBackend.updateConfiguration(next)
            configurationError = nil
        } catch {
            // Preserve the in-memory change so notification and policy previews
            // remain usable even when macOS temporarily denies persistence.
            configuration = next
            endpointSecurityBackend.updateConfiguration(next)
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

    func openFullDiskAccessSettings() {
        let urls = [
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
        ].compactMap { $0 }
        guard urls.contains(where: { NSWorkspace.shared.open($0) }) else {
            configurationError = "无法自动打开完全磁盘访问设置，请从系统设置 > 隐私与安全性 > 完全磁盘访问手动打开。"
            return
        }
        configurationError = nil
    }

    func revealCurrentApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func copyCurrentApplicationPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Bundle.main.bundleURL.path, forType: .string)
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
        let configuredAction = decision?.action ?? rule.action
        appendAudit(.init(
            id: eventID,
            source: .simulation,
            kind: .fileOpen,
            ruleName: rule.name,
            configuredAction: configuredAction
        ))
        notificationError = nil
        notificationCoordinator.sendTestEvent(
            id: eventID,
            ruleName: rule.name,
            configuredAction: configuredAction.label
        )
    }

    var auditStatistics: AuditStatistics { AuditStatistics(events: auditEvents) }

    private func appendAudit(_ event: AuditEvent) {
        auditEvents.insert(event, at: 0)
        auditEvents = Array(auditEvents.prefix(AuditFile.maxEventCount))
        do {
            try AuditFile.save(auditEvents, to: auditURL)
            auditError = nil
        } catch {
            auditError = "审计记录未能保存：\(error.localizedDescription)。当前记录仅保留在本次运行。"
        }
    }

    private func resolveNotification(_ id: UUID, action: NotificationAction) {
        guard let index = auditEvents.firstIndex(where: { $0.id == id }) else { return }
        if auditEvents[index].source == .endpointSecurity {
            switch action {
            case .allowOnce, .block:
                // A live AUTH_OPEN event owns the decision. Ignore stale taps
                // after its deadline so the audit log cannot claim that a file
                // was allowed after the kernel already denied it.
                _ = endpointSecurityBackend.resolveNotification(id, action: action)
                return
            case .open:
                auditEvents[index].outcome = .opened
            }
        } else {
            switch action {
            case .allowOnce: auditEvents[index].outcome = .allowedOnce
            case .block: auditEvents[index].outcome = .blocked
            case .open: auditEvents[index].outcome = .opened
            }
        }
        do {
            try AuditFile.save(auditEvents, to: auditURL)
            auditError = nil
        } catch {
            auditError = "审计记录未能保存：\(error.localizedDescription)。当前结果仅保留在本次运行。"
        }
    }

    private func handleEndpointMatch(_ request: EndpointSecurityRequest) {
        appendAudit(.init(
            id: request.id,
            source: .endpointSecurity,
            kind: .fileOpen,
            ruleName: request.ruleName,
            applicationName: request.applicationName,
            configuredAction: request.configuredAction
        ))
        if request.configuredAction == .ask || request.configuredAction == .block {
            notificationError = nil
            notificationCoordinator.sendDecisionEvent(
                id: request.id,
                ruleName: request.ruleName,
                configuredAction: request.configuredAction.label,
                applicationName: request.applicationName,
                requiresUserDecision: request.configuredAction == .ask
            )
        }
    }

    private func handleEndpointDecision(_ decision: EndpointSecurityDecision) {
        guard let index = auditEvents.firstIndex(where: { $0.id == decision.request.id }) else {
            appendAudit(.init(
                id: decision.request.id,
                source: .endpointSecurity,
                kind: .fileOpen,
                ruleName: decision.request.ruleName,
                applicationName: decision.request.applicationName,
                configuredAction: decision.request.configuredAction,
                outcome: decision.outcome
            ))
            return
        }
        auditEvents[index].outcome = decision.outcome
        do {
            try AuditFile.save(auditEvents, to: auditURL)
            auditError = nil
        } catch {
            auditError = "审计记录未能保存：\(error.localizedDescription)。当前结果仅保留在本次运行。"
        }
    }
}
