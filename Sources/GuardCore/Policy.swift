import Foundation

public enum RuleAction: String, Codable, CaseIterable, Sendable {
    case record, ask, block

    public var label: String {
        switch self {
        case .record: "仅记录"
        case .ask: "询问我"
        case .block: "阻止"
        }
    }

    public var iconName: String {
        switch self {
        case .record: "eye"
        case .ask: "questionmark.circle"
        case .block: "hand.raised"
        }
    }
}

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case desktop
    case cli
    case custom

    public var label: String {
        switch self {
        case .desktop: "桌面应用"
        case .cli: "CLI 运行时"
        case .custom: "自定义"
        }
    }
}

public enum PathScope: String, Codable, CaseIterable, Sendable {
    case file, directory

    public var label: String { self == .file ? "单个文件" : "整个目录" }
}

public struct WatchedApplication: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bundleIdentifier: String?
    /// Optional metadata. It is absent in older configuration files.
    public var agentKind: AgentKind?

    public init(
        id: UUID = UUID(), name: String, path: String, bundleIdentifier: String? = nil,
        agentKind: AgentKind? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.agentKind = agentKind
    }
}

public struct SensitivePathRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var scope: PathScope
    public var action: RuleAction
    public var enabled: Bool

    public init(
        id: UUID = UUID(), name: String, path: String,
        scope: PathScope = .file, action: RuleAction = .ask, enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.scope = scope
        self.action = action
        self.enabled = enabled
    }

    /// Shared conservative path matcher. It only compares normalized strings;
    /// it never opens files, resolves symlinks, or authorizes OS events itself.
    public func matches(path candidate: String, homeDirectory: String) -> Bool {
        guard enabled,
              let target = Self.normalized(path, homeDirectory: homeDirectory),
              let candidate = Self.normalized(candidate, homeDirectory: homeDirectory)
        else { return false }
        if candidate == target { return true }
        return scope == .directory && candidate.hasPrefix(target == "/" ? "/" : target + "/")
    }

    private static func normalized(_ path: String, homeDirectory: String) -> String? {
        let expanded: String
        if path == "~" { expanded = homeDirectory }
        else if path.hasPrefix("~/") { expanded = homeDirectory + String(path.dropFirst()) }
        else { expanded = path }
        guard expanded.hasPrefix("/") else { return nil }
        var components: [Substring] = []
        for component in expanded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }
}

public struct GuardConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var applications: [WatchedApplication] = []
    public var rules: [SensitivePathRule] = []

    public init() {}

    public static let suggestedRules: [SensitivePathRule] = [
        .init(name: "SSH Ed25519 私钥", path: "~/.ssh/id_ed25519"),
        .init(name: "SSH RSA 私钥", path: "~/.ssh/id_rsa"),
        .init(name: "AWS 凭据文件", path: "~/.aws/credentials"),
    ]
}

public struct RulePreview: Equatable, Sendable {
    public let action: RuleAction
    public let ruleIDs: [UUID]
}

public enum PolicyPreview {
    /// Selects the strongest configured action. This is never an enforcement verdict.
    public static func evaluate(
        path: String, rules: [SensitivePathRule], homeDirectory: String
    ) -> RulePreview? {
        let matches = rules.filter { $0.matches(path: path, homeDirectory: homeDirectory) }
        guard !matches.isEmpty else { return nil }
        let action: RuleAction = matches.contains { $0.action == .block } ? .block
            : matches.contains { $0.action == .ask } ? .ask : .record
        return RulePreview(action: action, ruleIDs: matches.map(\.id))
    }
}

/// A policy match used by enforcement transports. Keeping this in GuardCore
/// prevents the UI process and a future privileged helper from implementing
/// subtly different application/path matching rules.
public struct FileAccessPolicyMatch: Equatable, Sendable {
    public let application: WatchedApplication
    public let rules: [SensitivePathRule]
    public let action: RuleAction

    public var primaryRule: SensitivePathRule? {
        rules.first(where: { $0.action == action }) ?? rules.first
    }

    public init(
        application: WatchedApplication,
        rules: [SensitivePathRule],
        action: RuleAction
    ) {
        self.application = application
        self.rules = rules
        self.action = action
    }
}

public enum FileAccessPolicy {
    /// Matches one executable event against the configured application and
    /// sensitive-path rules. This is a pure function: it never touches the
    /// filesystem and never makes an operating-system authorization decision.
    public static func evaluate(
        path: String,
        executablePath: String,
        configuration: GuardConfiguration,
        homeDirectory: String
    ) -> FileAccessPolicyMatch? {
        guard let application = configuration.applications.first(where: {
            applicationMatches(configuredPath: $0.path, executablePath: executablePath)
        }) else { return nil }
        guard let preview = PolicyPreview.evaluate(
            path: path,
            rules: configuration.rules,
            homeDirectory: homeDirectory
        ) else { return nil }
        let rules = configuration.rules.filter { preview.ruleIDs.contains($0.id) }
        return FileAccessPolicyMatch(application: application, rules: rules, action: preview.action)
    }

    public static func applicationMatches(configuredPath: String, executablePath: String) -> Bool {
        let configured = normalize(configuredPath)
        let executable = normalize(executablePath)
        if configured == executable { return true }
        // Selecting an .app protects only executables below Contents/. A
        // similarly named sibling bundle or helper remains outside the match.
        return configured.hasSuffix(".app") && executable.hasPrefix(configured + "/Contents/")
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public enum ConfigurationError: LocalizedError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "不支持配置版本 \(version)，原文件保持不变。"
        }
    }
}

public enum ConfigurationFile {
    public static func load(from url: URL) throws -> GuardConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let value = try JSONDecoder().decode(GuardConfiguration.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else { throw ConfigurationError.unsupportedSchema(value.schemaVersion) }
        return value
    }

    public static func save(_ value: GuardConfiguration, to url: URL) throws {
        guard value.schemaVersion == 1 else { throw ConfigurationError.unsupportedSchema(value.schemaVersion) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The application directory is private; restrict the final configuration file as well.
        // File protection options are intended for iOS data-protection classes and can
        // make a development macOS app unable to reopen its own configuration. The
        // private directory plus 0600 file mode provide the local boundary here.
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
