import Combine
import Darwin
import EndpointSecurity
import Foundation
import GuardCore

enum EndpointSecurityState: Equatable {
    case notStarted
    case available
    case unavailable(reason: String)

    var label: String {
        switch self {
        case .notStarted: "未检测"
        case .available: "已订阅"
        case .unavailable: "未启用"
        }
    }

    var detail: String {
        switch self {
        case .notStarted: "尚未探测 Endpoint Security"
        case .available: "已订阅 AUTH_OPEN；只有同时匹配受保护应用和重点文件的访问才会进入决定流程。"
        case .unavailable(let reason): reason
        }
    }
}

struct EndpointSecurityRequest: Identifiable, Sendable {
    let id: UUID
    let ruleName: String
    let applicationName: String
    let configuredAction: RuleAction
}

struct EndpointSecurityDecision: Sendable {
    let request: EndpointSecurityRequest
    let outcome: AuditOutcome
}

private enum EndpointSecurityVerdict: Sendable {
    case allow
    case deny
}

private final class PendingDecision: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var verdict: EndpointSecurityVerdict?

    func resolve(_ verdict: EndpointSecurityVerdict) {
        lock.lock()
        guard self.verdict == nil else {
            lock.unlock()
            return
        }
        self.verdict = verdict
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> EndpointSecurityVerdict? {
        guard timeout > 0 else { return nil }
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return verdict
    }
}

/// The object captured by the C Endpoint Security callback. It owns no UI and
/// contains only a locked configuration snapshot plus bounded pending asks, so
/// the serial ES handler never touches a MainActor object directly.
private final class EndpointSecurityRuntime: @unchecked Sendable {
    private struct Snapshot {
        var configuration = GuardConfiguration()
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var pending: [UUID: PendingDecision] = [:]
    private var onMatched: (@Sendable (EndpointSecurityRequest) -> Void)?
    private var onDecision: (@Sendable (EndpointSecurityDecision) -> Void)?

    func update(configuration: GuardConfiguration) {
        lock.lock()
        snapshot.configuration = configuration
        lock.unlock()
    }

    func setCallbacks(
        onMatched: (@Sendable (EndpointSecurityRequest) -> Void)?,
        onDecision: (@Sendable (EndpointSecurityDecision) -> Void)?
    ) {
        lock.lock()
        self.onMatched = onMatched
        self.onDecision = onDecision
        lock.unlock()
    }

    func resolve(id: UUID, verdict: EndpointSecurityVerdict) -> Bool {
        lock.lock()
        let decision = pending[id]
        lock.unlock()
        guard let decision else { return false }
        decision.resolve(verdict)
        return true
    }

    func cancelPending() {
        lock.lock()
        let decisions = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        decisions.forEach { $0.resolve(.deny) }
    }

    /// Returns a decision for a configured event, or nil when the event should
    /// be allowed without an audit entry. The caller must respond to every
    /// AUTH_OPEN message, including the nil case.
    func evaluate(
        path: String,
        executablePath: String,
        authorizationBudget: TimeInterval
    ) -> EndpointSecurityDecision? {
        lock.lock()
        let configuration = snapshot.configuration
        let matchedCallback = onMatched
        let decisionCallback = onDecision
        lock.unlock()

        guard let application = configuration.applications.first(where: {
            Self.applicationMatches($0.path, executablePath: executablePath)
        }) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let preview = PolicyPreview.evaluate(
            path: path,
            rules: configuration.rules,
            homeDirectory: home
        ), let rule = configuration.rules.first(where: {
            preview.ruleIDs.contains($0.id) && $0.action == preview.action
        }) ?? configuration.rules.first(where: { preview.ruleIDs.contains($0.id) }) else {
            return nil
        }

        let request = EndpointSecurityRequest(
            id: UUID(),
            ruleName: rule.name,
            applicationName: application.name,
            configuredAction: preview.action
        )
        matchedCallback?(request)

        switch preview.action {
        case .record:
            let decision = EndpointSecurityDecision(request: request, outcome: .recorded)
            decisionCallback?(decision)
            return decision
        case .block:
            let decision = EndpointSecurityDecision(request: request, outcome: .blocked)
            decisionCallback?(decision)
            return decision
        case .ask:
            let wait = PendingDecision()
            lock.lock()
            pending[request.id] = wait
            lock.unlock()

            // The callback schedules a notification on the main actor. The
            // authorization path remains bounded by the kernel deadline.
            let verdict = wait.wait(timeout: authorizationBudget)
            lock.lock()
            pending.removeValue(forKey: request.id)
            lock.unlock()

            let outcome: AuditOutcome
            switch verdict {
            case .some(.allow): outcome = .allowedOnce
            case .some(.deny): outcome = .blocked
            case .none: outcome = .timedOut
            }
            let decision = EndpointSecurityDecision(request: request, outcome: outcome)
            decisionCallback?(decision)
            return decision
        }
    }

    private static func applicationMatches(_ configuredPath: String, executablePath: String) -> Bool {
        let configured = normalize(configuredPath)
        let executable = normalize(executablePath)
        if configured == executable { return true }
        // The UI stores an .app bundle path while ES reports the actual helper
        // executable. Restrict the relationship to Contents/ so a similarly
        // named sibling cannot become protected accidentally.
        return configured.hasSuffix(".app") && executable.hasPrefix(configured + "/Contents/")
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Endpoint Security capability and AUTH_OPEN enforcement seam.
@MainActor
final class EndpointSecurityBackend: ObservableObject {
    @Published private(set) var state: EndpointSecurityState = .notStarted
    private var client: OpaquePointer?
    private let runtime = EndpointSecurityRuntime()

    var onMatched: (@MainActor @Sendable (EndpointSecurityRequest) -> Void)?
    var onDecision: (@MainActor @Sendable (EndpointSecurityDecision) -> Void)?

    init() {
        runtime.setCallbacks(
            onMatched: { [weak self] request in
                Task { @MainActor [weak self] in self?.onMatched?(request) }
            },
            onDecision: { [weak self] decision in
                Task { @MainActor [weak self] in self?.onDecision?(decision) }
            }
        )
    }

    func updateConfiguration(_ configuration: GuardConfiguration) {
        runtime.update(configuration: configuration)
    }

    func probe() {
        guard client == nil else {
            state = .available
            return
        }

        var newClient: OpaquePointer?
        let runtime = self.runtime
        let result = es_new_client(&newClient) { client, message in
            Self.handle(client: client, message: message, runtime: runtime)
        }
        guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let newClient else {
            state = .unavailable(reason: Self.reason(for: result))
            return
        }

        let events = [ES_EVENT_TYPE_AUTH_OPEN]
        let subscriptionResult = events.withUnsafeBufferPointer {
            es_subscribe(newClient, $0.baseAddress!, UInt32($0.count))
        }
        guard subscriptionResult == ES_RETURN_SUCCESS else {
            _ = es_delete_client(newClient)
            state = .unavailable(reason: "Endpoint Security 订阅 AUTH_OPEN 失败：\(subscriptionResult.rawValue)")
            return
        }
        client = newClient
        state = .available
    }

    func resolveNotification(_ id: UUID, action: NotificationAction) -> Bool {
        switch action {
        case .allowOnce:
            return runtime.resolve(id: id, verdict: .allow)
        case .block:
            return runtime.resolve(id: id, verdict: .deny)
        case .open:
            return false
        }
    }

    func stop() {
        runtime.cancelPending()
        guard let client else {
            state = .notStarted
            return
        }
        _ = es_unsubscribe_all(client)
        _ = es_delete_client(client)
        self.client = nil
        state = .notStarted
    }

    private static func handle(
        client: OpaquePointer,
        message: UnsafePointer<es_message_t>,
        runtime: EndpointSecurityRuntime
    ) {
        guard message.pointee.event_type == ES_EVENT_TYPE_AUTH_OPEN else {
            _ = es_respond_flags_result(client, message, UInt32.max, false)
            return
        }

        let event = message.pointee.event.open
        let path = string(event.file.pointee.path)
        let executablePath = string(message.pointee.process.pointee.executable.pointee.path)
        let budget = authorizationBudget(for: message)
        let decision = runtime.evaluate(
            path: path,
            executablePath: executablePath,
            authorizationBudget: budget
        )
        let authorizedFlags: UInt32 = decision?.outcome == .blocked || decision?.outcome == .timedOut
            ? 0
            : UInt32.max
        _ = es_respond_flags_result(client, message, authorizedFlags, false)
    }

    private static func string(_ token: es_string_token_t) -> String {
        guard let data = token.data else { return "" }
        let buffer = UnsafeBufferPointer(start: data, count: Int(token.length))
        return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func authorizationBudget(for message: UnsafePointer<es_message_t>) -> TimeInterval {
        let deadline = message.pointee.deadline
        let now = mach_absolute_time()
        guard deadline > now else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanoseconds = Double(deadline - now)
            * Double(timebase.numer)
            / Double(timebase.denom)
        // Keep a small response margin and cap the UI wait. The cap prevents a
        // notification delay from monopolizing the serial ES handler.
        return min(4.0, max(0, nanoseconds / 1_000_000_000 - 0.05))
    }

    private static func reason(for result: es_new_client_result_t) -> String {
        switch result {
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED:
            "缺少 Endpoint Security entitlement（开发预览未申请）"
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
            "系统未授予 Endpoint Security 权限，请将签名后的应用加入完全磁盘访问权限"
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED:
            "Endpoint Security 客户端必须运行在 root 特权 helper/LaunchDaemon 中；当前菜单栏应用不能直接订阅"
        case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS:
            "系统中的 Endpoint Security 客户端数量已达上限"
        default:
            "Endpoint Security 返回错误：\(result.rawValue)"
        }
    }
}
