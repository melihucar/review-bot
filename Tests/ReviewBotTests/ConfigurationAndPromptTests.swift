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
