import CryptoKit
import Foundation
import Testing
@testable import Toasty

@Suite struct ClaudeSDKTests {
    typealias Option = ClaudeSDK.Option
    let bundled = Option(version: "0.3.319", claudeCode: "2.1.319", path: nil)

    func download(_ v: String, _ cc: String) -> Option { Option(version: v, claudeCode: cc, path: "/sdk/\(v)/sdk.mjs") }

    @Test func parsesBundledVersionFile() {
        let text = "@anthropic-ai/claude-agent-sdk 0.3.319 (sdk.mjs, built for Claude Code 2.1.319), vendored unmodified."
        #expect(ClaudeSDK.parseBundled(text) == bundled)
    }

    @Test func picksNewestBuiltForInstalledClaude() {
        let options = [bundled, download("0.3.322", "2.1.322"), download("0.3.325", "2.1.325")]
        #expect(ClaudeSDK.pick(options, claude: "2.1.324", skip: [])?.version == "0.3.322")
        #expect(ClaudeSDK.pick(options, claude: "2.1.330", skip: [])?.version == "0.3.325")
    }

    @Test func fallsBackPastBadAndExcludedVersions() {
        let options = [bundled, download("0.3.322", "2.1.322"), download("0.3.325", "2.1.325")]
        #expect(ClaudeSDK.pick(options, claude: "2.1.330", skip: ["0.3.325"])?.version == "0.3.322")
        #expect(ClaudeSDK.pick(options, claude: "2.1.330", skip: ["0.3.325", "0.3.322"])?.version == "0.3.319")
    }

    @Test func bundledIsNeverSkipped() {
        #expect(ClaudeSDK.pick([bundled], claude: "2.1.330", skip: ["0.3.319"]) == bundled)
    }

    @Test func unknownClaudeUsesBundled() {
        #expect(ClaudeSDK.pick([bundled, download("0.3.325", "2.1.325")], claude: nil, skip: []) == bundled)
    }

    @Test func claudeOlderThanBundledLeavesNothing() {
        // The caller falls back to the bundled copy; a matching older SDK
        // is what `candidates` then downloads.
        #expect(ClaudeSDK.pick([bundled], claude: "2.1.310", skip: []) == nil)
        #expect(ClaudeSDK.candidates(available: ["0.3.309", "0.3.310", "0.3.311"], claude: "2.1.310", bundled: bundled)
            == ["0.3.310", "0.3.309"])
    }

    @Test func candidatesSkipMissingReleasesAndPrereleases() {
        // 0.3.313 was never published; 0.3.330-beta.1 is a prerelease.
        let available = ["0.3.311", "0.3.312", "0.3.314", "0.3.330-beta.1", "0.3.331", "0.2.99", "1.0.0"]
        #expect(ClaudeSDK.candidates(available: available, claude: "2.1.313", bundled: bundled) == ["0.3.312", "0.3.311"])
    }

    @Test func candidatesStopAtAVersionSchemeChange() {
        #expect(ClaudeSDK.candidates(available: ["0.3.5", "0.4.1"], claude: "2.2.1", bundled: bundled).isEmpty)
    }

    @Test func comparesNumerically() {
        #expect(ClaudeSDK.compare("0.3.99", "0.3.100") == .orderedAscending)
        #expect(ClaudeSDK.compare("2.1.319", "2.1.319") == .orderedSame)
    }

    @Test func verifiesNpmIntegrity() {
        let data = Data("hello".utf8)
        let good = "sha512-" + Data(SHA512.hash(data: data)).base64EncodedString()
        #expect(ClaudeSDK.verify(data, integrity: good))
        #expect(!ClaudeSDK.verify(Data("hellO".utf8), integrity: good))
        #expect(!ClaudeSDK.verify(data, integrity: "sha1-abc"))
    }
}

/// Downloads a real SDK from npm into the Debug app's SDK folder, then
/// removes it. Opt-in: `TOASTY_NETWORK_TESTS=1` (needs network and node).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOASTY_NETWORK_TESTS"] == "1"))
struct ClaudeSDKNetworkTests {
    @Test func downloadsVerifiesAndInstallsTheMatchingSDK() async throws {
        let node = try #require(["/opt/homebrew/bin/node", "/usr/local/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? ProcessInfo.processInfo.environment["TOASTY_NODE"])
        let bridge = try #require(Bundle.main.url(forResource: "toasty-agent", withExtension: "mjs", subdirectory: "Bridge"))
        // Pretend the bundled SDK is one behind 0.3.319.
        let older = ClaudeSDK.Option(version: "0.3.318", claudeCode: "2.1.318", path: nil)
        let dest = ClaudeSDK.root.appendingPathComponent("0.3.319")
        defer { try? FileManager.default.removeItem(at: dest) }

        let outcome = await ClaudeSDK.update(claude: "2.1.319", bundled: older, have: ["0.3.318"], bad: [],
                                             node: node, bridge: bridge.path, environment: [:])
        guard case .installed("0.3.319") = outcome else { Issue.record("got \(outcome)"); return }
        let found = ClaudeSDK.scanInstalled(at: ClaudeSDK.root).first { $0.version == "0.3.319" }
        #expect(found?.claudeCode == "2.1.319")
    }
}
