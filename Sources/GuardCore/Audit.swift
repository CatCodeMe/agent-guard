import Foundation

/// Identifies where an audit event came from. Simulation events are kept so
/// the notification flow can be tested without pretending to be enforcement.
public enum AuditSource: String, Codable, CaseIterable, Sendable {
    case simulation
    case endpointSecurity

    public var label: String {
        switch self {
        case .simulation: "模拟"
        case .endpointSecurity: "Endpoint Security"
        }
    }
}

public enum AuditEventKind: String, Codable, CaseIterable, Sendable {
    case fileOpen
    case notificationAction

    public var label: String {
        switch self {
        case .fileOpen: "文件访问"
        case .notificationAction: "通知操作"
        }
    }
}

/// The persisted outcome is deliberately separate from the configured rule
/// action. For example, an `ask` rule can end as `allowedOnce`, `blocked`, or
/// `timedOut` depending on the user's response and the authorization deadline.
public enum AuditOutcome: String, Codable, CaseIterable, Sendable {
    case pending
    case recorded
    case allowedOnce
    case blocked
    case timedOut
    case opened

    public var label: String {
        switch self {
        case .pending: "等待用户操作"
        case .recorded: "已记录并放行"
        case .allowedOnce: "用户选择允许一次"
        case .blocked: "已阻止"
        case .timedOut: "超时后阻止"
        case .opened: "用户打开 Agent Guard"
        }
    }

    public var iconName: String {
        switch self {
        case .pending: "bell.badge"
        case .recorded: "eye"
        case .allowedOnce: "checkmark.circle.fill"
        case .blocked: "hand.raised.fill"
        case .timedOut: "clock.badge.exclamationmark"
        case .opened: "arrow.up.forward.app.fill"
        }
    }
}

public struct AuditEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let source: AuditSource
    public let kind: AuditEventKind
    public let ruleName: String
    public let applicationName: String?
    public let configuredAction: RuleAction
    public var outcome: AuditOutcome

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        source: AuditSource,
        kind: AuditEventKind = .fileOpen,
        ruleName: String,
        applicationName: String? = nil,
        configuredAction: RuleAction,
        outcome: AuditOutcome = .pending
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.kind = kind
        self.ruleName = ruleName
        self.applicationName = applicationName
        self.configuredAction = configuredAction
        self.outcome = outcome
    }
}

public struct AuditStatistics: Equatable, Sendable {
    public let total: Int
    public let pending: Int
    public let recorded: Int
    public let allowedOnce: Int
    public let blocked: Int
    public let timedOut: Int
    public let opened: Int

    public init(events: [AuditEvent]) {
        total = events.count
        pending = events.filter { $0.outcome == .pending }.count
        recorded = events.filter { $0.outcome == .recorded }.count
        allowedOnce = events.filter { $0.outcome == .allowedOnce }.count
        blocked = events.filter { $0.outcome == .blocked }.count
        timedOut = events.filter { $0.outcome == .timedOut }.count
        opened = events.filter { $0.outcome == .opened }.count
    }

    public static let empty = AuditStatistics(events: [])
}

public enum AuditFile {
    public static let maxEventCount = 500

    public static func load(from url: URL) throws -> [AuditEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let events = try JSONDecoder().decode([AuditEvent].self, from: Data(contentsOf: url))
        return Array(events.sorted { $0.date > $1.date }.prefix(maxEventCount))
    }

    public static func save(_ events: [AuditEvent], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bounded = Array(events.sorted { $0.date > $1.date }.prefix(maxEventCount))
        try encoder.encode(bounded).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
