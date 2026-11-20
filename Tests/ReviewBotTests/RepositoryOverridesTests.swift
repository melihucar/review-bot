import XCTest
@testable import ReviewBot

final class RepositoryOverridesTests: XCTestCase {
    private let loosePolicy = DecisionPolicy(shouldFix: .approve, nitsOnly: .approve, clean: .comment)

    private func decode(_ json: String) throws -> ReviewBotConfiguration {
        try JSONDecoder().decode(ReviewBotConfiguration.self, from: Data(json.utf8))
    }

    private func widget(overrides: RepositoryOverrides = .empty, slug: String = "acme/widget") -> RepositoryConfiguration {
        RepositoryConfiguration(
            name: slug.split(separator: "/").last.map(String.init) ?? slug,
            path: "/projects/\(slug)",
            githubSlug: slug,
            overrides: overrides
        )
    }

    // MARK: Decoding

    func testALegacyRepositoryEntryHasNoOverrides() throws {
        let json = #"""
        {
          "repositories": [
            { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "widget",
              "path": "/projects/widget", "githubSlug": "acme/widget", "enabled": false }
          ]
        }
        """#

        let repository = try XCTUnwrap(decode(json).repositories.first)

        XCTAssertEqual(repository.overrides, .empty)
        XCTAssertNil(repository.overrides.summary)
    }

    func testRepositoryOverridesDecodeFromTheConfiguration() throws {
        let json = #"""
        {
          "repositories": [
            { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "widget",
              "path": "/projects/widget", "githubSlug": "acme/widget",
              "overrides": {
                "decisionPolicy": { "shouldFix": "approve", "nitsOnly": "approve", "clean": "comment" },
                "prompt": "Billing needs tests.",
                "promptMode": "replace"
              } }
          ]
        }
        """#

        let overrides = try XCTUnwrap(decode(json).repositories.first).overrides

        XCTAssertEqual(overrides.decisionPolicy, loosePolicy)
        XCTAssertEqual(overrides.prompt, "Billing needs tests.")
        XCTAssertEqual(overrides.promptMode, .replace)
    }

    func testRepositoryOverridesRoundTrip() throws {
        var original = ReviewBotConfiguration.default
        original.repositories = [
            widget(
                overrides: RepositoryOverrides(decisionPolicy: loosePolicy, prompt: "Local", promptMode: .replace)
            ),
            widget(slug: "acme/gadget"),
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReviewBotConfiguration.self, from: data)

        XCTAssertEqual(decoded.repositories, original.repositories)
    }

    func testUnreadableOverridesFollowTheGlobalSettingsWithoutLosingTheConfiguration() throws {
        let json = #"""
        {
          "pollIntervalMinutes": 30,
          "repositories": [
            { "name": "a", "path": "/a", "githubSlug": "acme/a", "overrides": 7 },
            { "name": "b", "path": "/b", "githubSlug": "acme/b",
              "overrides": { "decisionPolicy": { "shouldFix": "explode" },
                             "prompt": "Keep me", "promptMode": "shout" } },
            { "name": "c", "path": "/c", "githubSlug": "acme/c", "overrides": { "prompt": 5 } }
          ]
        }
        """#

        let configuration = try decode(json)

        XCTAssertEqual(configuration.pollIntervalMinutes, 30)
        XCTAssertEqual(configuration.repositories.count, 3)
        XCTAssertEqual(configuration.repositories[0].overrides, .empty)
        XCTAssertNil(configuration.repositories[1].overrides.decisionPolicy)
        XCTAssertEqual(configuration.repositories[1].overrides.prompt, "Keep me")
        XCTAssertEqual(configuration.repositories[1].overrides.promptMode, .append)
        XCTAssertEqual(configuration.repositories[2].overrides.prompt, "")
    }

    // MARK: Resolver

    func testARepositoryWithoutOverridesResolvesToTheGlobalSettings() {
        var configuration = ReviewBotConfiguration.default
        configuration.decisionPolicy = loosePolicy
        configuration.customPrompt = "  Global  "

        let effective = configuration.effectiveSettings(for: widget())

        XCTAssertEqual(effective.decisionPolicy, loosePolicy)
        XCTAssertFalse(effective.usesRepositoryDecisionPolicy)
        XCTAssertEqual(effective.developerPrompt, "Global")
        XCTAssertEqual(effective.repositoryPrompt, "")
    }

    func testAPolicyOverrideAppliesOnlyToItsRepository() {
        var configuration = ReviewBotConfiguration.default
        let overridden = widget(overrides: RepositoryOverrides(decisionPolicy: loosePolicy))
        let plain = widget(slug: "acme/gadget")
        configuration.repositories = [overridden, plain]

        let first = configuration.effectiveSettings(for: overridden)
        let second = configuration.effectiveSettings(for: plain)

        XCTAssertEqual(first.decisionPolicy, loosePolicy)
        XCTAssertTrue(first.usesRepositoryDecisionPolicy)
        XCTAssertEqual(second.decisionPolicy, configuration.decisionPolicy)
        XCTAssertFalse(second.usesRepositoryDecisionPolicy)
    }

    func testAnAppendedPromptFollowsTheGlobalOne() {
        var configuration = ReviewBotConfiguration.default
        configuration.customPrompt = "Global"

        let effective = configuration.effectiveSettings(
            for: widget(overrides: RepositoryOverrides(prompt: "Local", promptMode: .append))
        )

        XCTAssertEqual(effective.developerPrompt, "Global")
        XCTAssertEqual(effective.repositoryPrompt, "Local")
    }

    func testAnAppendedPromptStandsAloneWhenThereIsNoGlobalOne() {
        var configuration = ReviewBotConfiguration.default
        configuration.customPrompt = ""

        let effective = configuration.effectiveSettings(
            for: widget(overrides: RepositoryOverrides(prompt: "Local", promptMode: .append))
        )

        XCTAssertEqual(effective.developerPrompt, "Local")
        XCTAssertEqual(effective.repositoryPrompt, "")
    }

    func testAReplacingPromptDropsTheGlobalOne() {
        var configuration = ReviewBotConfiguration.default
        configuration.customPrompt = "Global"

        let effective = configuration.effectiveSettings(
            for: widget(overrides: RepositoryOverrides(prompt: "Local", promptMode: .replace))
        )

        XCTAssertEqual(effective.developerPrompt, "Local")
        XCTAssertEqual(effective.repositoryPrompt, "")
    }

    func testABlankPromptNeverRemovesTheGlobalOne() {
        var configuration = ReviewBotConfiguration.default
        configuration.customPrompt = "Global"

        let effective = configuration.effectiveSettings(
            for: widget(overrides: RepositoryOverrides(prompt: " \n", promptMode: .replace))
        )

        XCTAssertEqual(effective.developerPrompt, "Global")
        XCTAssertEqual(effective.repositoryPrompt, "")
    }

    func testNormalizedDropsTheModeOfABlankPrompt() {
        let blank = RepositoryOverrides(prompt: " ", promptMode: .replace)

        XCTAssertEqual(blank.normalized, .empty)
        XCTAssertTrue(blank.isEmpty)
        XCTAssertEqual(
            RepositoryOverrides(decisionPolicy: loosePolicy, prompt: " ", promptMode: .replace).normalized,
            RepositoryOverrides(decisionPolicy: loosePolicy)
        )
    }

    func testSummaryNamesWhatIsOverridden() {
        XCTAssertNil(RepositoryOverrides.empty.summary)
        XCTAssertEqual(RepositoryOverrides(decisionPolicy: loosePolicy).summary, "Own decision policy")
        XCTAssertEqual(RepositoryOverrides(prompt: "Local").summary, "Adds review instructions")
        XCTAssertEqual(
            RepositoryOverrides(decisionPolicy: loosePolicy, prompt: "Local", promptMode: .replace).summary,
            "Own decision policy · Replaces the global instructions"
        )
    }

    // MARK: Storage

    @MainActor
    func testSettingsStoreSavesNormalizedOverridesAndIgnoresAnUnknownRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotOverridesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let store = SettingsStore(paths: paths)
        let repository = widget()
        store.add(repository)

        let overrides = RepositoryOverrides(decisionPolicy: loosePolicy, prompt: "Local")
        store.setOverrides(overrides, forRepository: repository.id)

        XCTAssertEqual(SettingsStore(paths: paths).configuration.repositories.first?.overrides, overrides)

        let before = store.configuration
        store.setOverrides(RepositoryOverrides(prompt: "Nope"), forRepository: UUID())
        XCTAssertEqual(store.configuration, before)

        store.setOverrides(RepositoryOverrides(prompt: " ", promptMode: .replace), forRepository: repository.id)
        XCTAssertEqual(store.configuration.repositories.first?.overrides, .empty)
    }
}
