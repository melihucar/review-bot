import XCTest
@testable import ReviewBot

final class ConfigurationAndPromptTests: XCTestCase {
    func testOlderConfigurationDefaultsToActiveFifteenMinutePolling() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "customPrompt": "Focus on migrations"
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(configuration.pollIntervalMinutes, 15)
        XCTAssertFalse(configuration.isPaused)
        XCTAssertEqual(configuration.customPrompt, "Focus on migrations")
        XCTAssertEqual(configuration.reviewScope, .fullPullRequest)
        XCTAssertNil(configuration.maxReviewRoundsPerPR)
    }

    func testMaxReviewRoundsDecodesAndClampsToAtLeastOne() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "customPrompt": "",
          "maxReviewRoundsPerPR": 0
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        // 0 is meaningless as a cap; it is clamped up to 1.
        XCTAssertEqual(configuration.maxReviewRoundsPerPR, 1)
    }

    func testReviewScopeDecodesWhenPresent() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "customPrompt": "",
          "reviewScope": "incremental"
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(configuration.reviewScope, .incremental)
    }

    func testLastReviewedStoreRoundTripsHeadPerPullRequest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotLastReviewed-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(root: root)
        try paths.prepare()

        let store = LastReviewedStore(paths: paths)
        XCTAssertNil(store.head(for: "acme/widget#42"))

        store.record("acme/widget#42", head: "deadbeef")
        XCTAssertEqual(store.head(for: "acme/widget#42"), "deadbeef")

        // A fresh store reloads persisted heads from disk.
        let reloaded = LastReviewedStore(paths: paths)
        XCTAssertEqual(reloaded.head(for: "acme/widget#42"), "deadbeef")
        XCTAssertNil(reloaded.head(for: "acme/widget#99"))
    }

    func testRepositoryRulesAndCustomizationAreAddedToPrompt() {
        let prompt = DefaultPrompt.combined(
            with: "Run the project's formatter.",
            repositoryRules: "Treat database rollbacks as Blocking."
        )

        XCTAssertTrue(prompt.contains("Developer-specific review instructions"))
        XCTAssertTrue(prompt.contains("Run the project's formatter."))
        XCTAssertTrue(prompt.contains("Mandatory repository review rules"))
        XCTAssertTrue(prompt.contains("Treat database rollbacks as Blocking."))
        XCTAssertTrue(prompt.hasSuffix("--- END REVIEW.md ---"))
    }
}
