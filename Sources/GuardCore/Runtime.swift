import Foundation

public struct AgentPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: AgentKind
    public let candidatePaths: [String]

    public init(id: String, name: String, kind: AgentKind, candidatePaths: [String]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.candidatePaths = candidatePaths
    }
}

/// Known launch points are hints only. Discovery never starts or modifies a process.
public enum AgentCatalog {
    public static let common: [AgentPreset] = [
        .init(
            id: "codex",
            name: "Codex",
            kind: .desktop,
            candidatePaths: ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        ),
        .init(
            id: "codex-cli",
            name: "Codex CLI",
            kind: .cli,
            candidatePaths: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        ),
        .init(
            id: "claude",
            name: "Claude",
            kind: .desktop,
            candidatePaths: ["/Applications/Claude.app"]
        ),
        .init(
            id: "claude-code",
            name: "Claude Code",
            kind: .cli,
            candidatePaths: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        ),
        .init(
            id: "cursor",
            name: "Cursor",
            kind: .desktop,
            candidatePaths: ["/Applications/Cursor.app"]
        ),
    ]
}

public struct SandboxRuntimeStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case available
        case nodeOnly
        case unavailable
    }

    public let state: State
    public let executablePath: String?
    public let nodePath: String?

    public var label: String {
        switch state {
        case .available: "可选后端可用"
        case .nodeOnly: "检测到 Node，未检测到 srt"
        case .unavailable: "未安装（可选）"
        }
    }

    public var detail: String {
        switch state {
        case .available: "可用于受控启动 CLI，不接管已运行的桌面应用"
        case .nodeOnly: "可按需安装 @anthropic-ai/sandbox-runtime；当前不会自动安装"
        case .unavailable: "主程序不依赖 Node；需要时可单独安装 srt"
        }
    }
}

public enum SandboxRuntimeProbe {
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeStandardPaths: Bool = true
    ) -> SandboxRuntimeStatus {
        var pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // Finder-launched apps often receive a shorter PATH than a shell. Keep
        // discovery useful without invoking a shell or executing the command.
        if includeStandardPaths {
            pathEntries.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        }
        var seen = Set<String>()
        pathEntries = pathEntries.filter { seen.insert($0).inserted }
        let srt = findExecutable(named: "srt", in: pathEntries)
            ?? findExecutable(named: "sandbox-runtime", in: pathEntries)
        let node = findExecutable(named: "node", in: pathEntries)
        if let srt { return .init(state: .available, executablePath: srt, nodePath: node) }
        if let node { return .init(state: .nodeOnly, executablePath: nil, nodePath: node) }
        return .init(state: .unavailable, executablePath: nil, nodePath: nil)
    }

    private static func findExecutable(named name: String, in directories: [String]) -> String? {
        for directory in directories where !directory.isEmpty {
            let path = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

/// A shell-free process invocation for the optional `srt` wrapper.
/// The adapter deliberately does not start a process or translate interactive
/// `ask` rules into a fail-open sandbox policy.
public struct SandboxRuntimeInvocation: Equatable, Sendable {
    public let executablePath: String
    public let settingsPath: String?
    public let commandPath: String
    public let arguments: [String]

    public var processArguments: [String] {
        var result: [String] = []
        if let settingsPath {
            result.append(contentsOf: ["--settings", settingsPath])
        }
        result.append(commandPath)
        result.append(contentsOf: arguments)
        return result
    }
}

public enum SandboxRuntimeAdapter {
    public static func invocation(
        executablePath: String,
        settingsURL: URL?,
        commandPath: String,
        arguments: [String] = []
    ) -> SandboxRuntimeInvocation {
        .init(
            executablePath: executablePath,
            settingsPath: settingsURL?.path,
            commandPath: commandPath,
            arguments: arguments
        )
    }
}
