import Foundation
import XCTest
@testable import GuardCore

final class PolicyTests: XCTestCase {
    private let home = "/Users/tester"

    func testPrivateKeyRuleDoesNotMatchPublicKey() {
        let rule = SensitivePathRule(name: "Private key", path: "~/.ssh/id_ed25519")
        XCTAssertTrue(rule.matches(path: home + "/.ssh/id_ed25519", homeDirectory: home))
        XCTAssertFalse(rule.matches(path: home + "/.ssh/id_ed25519.pub", homeDirectory: home))
    }

    func testDirectoryBoundaryDoesNotMatchSimilarlyNamedSibling() {
        let rule = SensitivePathRule(name: "SSH", path: "~/.ssh", scope: .directory)
        XCTAssertTrue(rule.matches(path: home + "/.ssh/keys/private", homeDirectory: home))
        XCTAssertFalse(rule.matches(path: home + "/.ssh-backup/private", homeDirectory: home))
        XCTAssertFalse(rule.matches(path: home + "/.ssh/../public", homeDirectory: home))
    }

    func testDisabledRuleAndRelativePathNeverMatch() {
        var rule = SensitivePathRule(name: "Key", path: "~/.ssh/id_rsa")
        rule.enabled = false
        XCTAssertFalse(rule.matches(path: home + "/.ssh/id_rsa", homeDirectory: home))
        rule.enabled = true
        XCTAssertFalse(rule.matches(path: ".ssh/id_rsa", homeDirectory: home))
    }

    func testPreviewChoosesStrongestActionAndReturnsAllEvidence() {
        let rules: [SensitivePathRule] = [
            .init(name: "Directory", path: "~/.ssh", scope: .directory, action: .record),
            .init(name: "Private key", path: "~/.ssh/id_rsa", action: .block),
        ]
        let result = PolicyPreview.evaluate(path: home + "/.ssh/id_rsa", rules: rules, homeDirectory: home)
        XCTAssertEqual(result?.action, .block)
        XCTAssertEqual(result?.ruleIDs, rules.map(\.id))
        XCTAssertNil(PolicyPreview.evaluate(path: "/tmp/ordinary", rules: rules, homeDirectory: home))
    }

    func testFileAccessPolicyMatchesAppContentsAndSensitivePath() {
        var configuration = GuardConfiguration()
        configuration.applications = [
            .init(name: "Example", path: "/Applications/Example.app", agentKind: .desktop)
        ]
        configuration.rules = [
            .init(name: "SSH", path: "~/.ssh", scope: .directory, action: .block)
        ]

        let match = FileAccessPolicy.evaluate(
            path: home + "/.ssh/id_rsa",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            configuration: configuration,
            homeDirectory: home
        )
        XCTAssertEqual(match?.application.name, "Example")
        XCTAssertEqual(match?.primaryRule?.name, "SSH")
        XCTAssertEqual(match?.action, .block)
    }

    func testFileAccessPolicyDoesNotMatchSiblingOrUnconfiguredProcess() {
        var configuration = GuardConfiguration()
        configuration.applications = [
            .init(name: "Example", path: "/Applications/Example.app", agentKind: .desktop)
        ]
        configuration.rules = [
            .init(name: "SSH", path: "~/.ssh", scope: .directory, action: .block)
        ]

        XCTAssertNil(FileAccessPolicy.evaluate(
            path: home + "/.ssh/id_rsa",
            executablePath: "/Applications/Example.app-helper/Contents/MacOS/Helper",
            configuration: configuration,
            homeDirectory: home
        ))
        XCTAssertFalse(FileAccessPolicy.applicationMatches(
            configuredPath: "/Applications/Example.app",
            executablePath: "/Applications/Example.app-helper/Contents/MacOS/Helper"
        ))
    }

    func testConfigurationRoundTripAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("configuration.json")
        var configuration = GuardConfiguration()
        configuration.rules = [.init(name: "Key", path: "~/.ssh/id_rsa")]
        configuration.applications = [.init(name: "Test CLI", path: "/opt/test/agent")]
        try ConfigurationFile.save(configuration, to: url)
        XCTAssertEqual(try ConfigurationFile.load(from: url), configuration)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptConfigurationIsNotSilentlyReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("configuration.json")
        let bytes = Data("broken configuration".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try ConfigurationFile.load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFutureSchemaIsRejectedWithoutOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("configuration.json")
        let bytes = Data(#"{"schemaVersion":2,"applications":[],"rules":[]}"#.utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try ConfigurationFile.load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testOlderApplicationConfigurationCanOmitOptionalAgentKind() throws {
        let bytes = Data(#"{"schemaVersion":1,"applications":[{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","path":"/opt/legacy","bundleIdentifier":null}],"rules":[]}"#.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)
        let configuration = try ConfigurationFile.load(from: url)
        XCTAssertEqual(configuration.applications.first?.agentKind, nil)
    }

    func testSandboxRuntimeProbeDoesNotSearchOutsideProvidedPath() {
        let status = SandboxRuntimeProbe.current(environment: ["PATH": ""], includeStandardPaths: false)
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertNil(status.executablePath)
        XCTAssertNil(status.nodePath)
    }

    func testSandboxRuntimeInvocationKeepsArgumentsOutOfShell() {
        let invocation = SandboxRuntimeAdapter.invocation(
            executablePath: "/opt/homebrew/bin/srt",
            settingsURL: URL(fileURLWithPath: "/tmp/guard settings.json"),
            commandPath: "/bin/echo",
            arguments: ["$HOME", "a; echo unsafe"]
        )
        XCTAssertEqual(
            invocation.processArguments,
            ["--settings", "/tmp/guard settings.json", "/bin/echo", "$HOME", "a; echo unsafe"]
        )
    }

    func testAuditStatisticsSeparateConfiguredActionFromOutcome() {
        let events = [
            AuditEvent(source: .simulation, ruleName: "SSH", configuredAction: .ask, outcome: .blocked),
            AuditEvent(source: .endpointSecurity, ruleName: "AWS", configuredAction: .record, outcome: .recorded),
            AuditEvent(source: .simulation, ruleName: "SSH", configuredAction: .ask, outcome: .allowedOnce),
            AuditEvent(source: .simulation, ruleName: "SSH", configuredAction: .ask, outcome: .pending),
        ]
        let statistics = AuditStatistics(events: events)
        XCTAssertEqual(statistics.total, 4)
        XCTAssertEqual(statistics.blocked, 1)
        XCTAssertEqual(statistics.allowedOnce, 1)
        XCTAssertEqual(statistics.recorded, 1)
        XCTAssertEqual(statistics.pending, 1)
    }

    func testAuditFileRoundTripIsBoundedAndPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.json")
        let events = (0..<(AuditFile.maxEventCount + 7)).map { index in
            AuditEvent(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                source: .simulation,
                ruleName: "Rule \(index)",
                configuredAction: .record,
                outcome: .recorded
            )
        }
        try AuditFile.save(events, to: url)
        let loaded = try AuditFile.load(from: url)
        XCTAssertEqual(loaded.count, AuditFile.maxEventCount)
        XCTAssertEqual(loaded.first?.ruleName, "Rule \(AuditFile.maxEventCount + 6)")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
