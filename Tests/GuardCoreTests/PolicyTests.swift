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
}
