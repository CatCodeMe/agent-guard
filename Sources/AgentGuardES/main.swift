import Darwin
import Dispatch
import EndpointSecurity
import Foundation
import GuardCore

private struct Options {
    let configurationURL: URL
    let homeDirectory: String
}

private final class EnforcementRuntime: @unchecked Sendable {
    let configuration: GuardConfiguration
    let homeDirectory: String

    init(configuration: GuardConfiguration, homeDirectory: String) {
        self.configuration = configuration
        self.homeDirectory = homeDirectory
    }

    func action(path: String, executablePath: String) -> (RuleAction, String, String)? {
        guard let match = FileAccessPolicy.evaluate(
            path: path,
            executablePath: executablePath,
            configuration: configuration,
            homeDirectory: homeDirectory
        ), let rule = match.primaryRule else { return nil }
        return (match.action, rule.name, match.application.name)
    }
}

private func parseOptions() -> Options? {
    var configurationPath: String?
    var homeDirectory = ProcessInfo.processInfo.environment["AGENT_GUARD_HOME"]
    var index = 1
    while index < CommandLine.arguments.count {
        switch CommandLine.arguments[index] {
        case "--config":
            index += 1
            guard index < CommandLine.arguments.count else { return nil }
            configurationPath = CommandLine.arguments[index]
        case "--home":
            index += 1
            guard index < CommandLine.arguments.count else { return nil }
            homeDirectory = CommandLine.arguments[index]
        case "--help", "-h":
            print("Usage: AgentGuardES --config <configuration.json> --home <user-home>")
            exit(0)
        default:
            return nil
        }
        index += 1
    }
    guard let configurationPath, let homeDirectory, homeDirectory.hasPrefix("/") else {
        fputs("AgentGuardES requires --config and --home; root's /var/root is not the protected user's home.\n", stderr)
        return nil
    }
    return Options(configurationURL: URL(fileURLWithPath: configurationPath), homeDirectory: homeDirectory)
}

private func tokenString(_ token: es_string_token_t) -> String {
    guard let data = token.data else { return "" }
    let buffer = UnsafeBufferPointer(start: data, count: Int(token.length))
    return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func describe(_ result: es_new_client_result_t) -> String {
    switch result {
    case ES_NEW_CLIENT_RESULT_SUCCESS: return "success"
    case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED: return "not entitled"
    case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED: return "not privileged"
    case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED: return "not permitted (TCC/Full Disk Access)"
    case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS: return "too many clients"
    case ES_NEW_CLIENT_RESULT_ERR_INVALID_ARGUMENT: return "invalid argument"
    default: return "error \(result.rawValue)"
    }
}

guard geteuid() == 0 else {
    fputs("AgentGuardES must run as root; refusing to start as a menu-bar user process.\n", stderr)
    exit(77)
}

guard let options = parseOptions() else { exit(64) }
let configuration: GuardConfiguration
do {
    configuration = try ConfigurationFile.load(from: options.configurationURL)
} catch {
    fputs("Unable to load configuration: \(error.localizedDescription)\n", stderr)
    exit(78)
}

private let runtime = EnforcementRuntime(configuration: configuration, homeDirectory: options.homeDirectory)
var client: OpaquePointer?
let result = es_new_client(&client) { client, message in
    guard message.pointee.event_type == ES_EVENT_TYPE_AUTH_OPEN else {
        _ = es_respond_flags_result(client, message, UInt32.max, false)
        return
    }

    let event = message.pointee.event.open
    let path = tokenString(event.file.pointee.path)
    let executablePath = tokenString(message.pointee.process.pointee.executable.pointee.path)
    guard let (action, ruleName, applicationName) = runtime.action(
        path: path,
        executablePath: executablePath
    ) else {
        _ = es_respond_flags_result(client, message, UInt32.max, false)
        return
    }

    switch action {
    case .record:
        print("record rule=\(ruleName) app=\(applicationName)")
        _ = es_respond_flags_result(client, message, UInt32.max, false)
    case .block:
        print("block rule=\(ruleName) app=\(applicationName)")
        _ = es_respond_flags_result(client, message, 0, false)
    case .ask:
        // The helper/GUI IPC channel is the next seam. Until it exists, an
        // ask rule fails closed instead of pretending that a notification can
        // answer after the kernel deadline.
        print("block-ask-without-ipc rule=\(ruleName) app=\(applicationName)")
        _ = es_respond_flags_result(client, message, 0, false)
    }
}

guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let client else {
    fputs("Endpoint Security client unavailable: \(describe(result))\n", stderr)
    exit(Int32(result.rawValue))
}

let events = [ES_EVENT_TYPE_AUTH_OPEN]
let subscription = events.withUnsafeBufferPointer {
    es_subscribe(client, $0.baseAddress!, UInt32($0.count))
}
guard subscription == ES_RETURN_SUCCESS else {
    fputs("Unable to subscribe to AUTH_OPEN: \(subscription.rawValue)\n", stderr)
    _ = es_delete_client(client)
    exit(79)
}

print("AgentGuardES subscribed to AUTH_OPEN")
dispatchMain()
