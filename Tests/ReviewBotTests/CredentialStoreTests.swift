import XCTest
@testable import ReviewBot

/// These tests deliberately never write to the Keychain — they use a service name no install
/// owns, so every Keychain lookup misses and the environment override is what is under test.
/// A miss returns `errSecItemNotFound` without user interaction, so the suite cannot prompt.
final class CredentialStoreTests: XCTestCase {
    private let unusedService = "Review Bot tests — no such Keychain item"

    func testEnvironmentOverrideSuppliesKeyWithoutKeychain() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: ["ANTHROPIC_API_KEY": "sk-from-environment"]
        )
        XCTAssertEqual(store.apiKey(for: .claude), "sk-from-environment")
    }

    func testEnvironmentOverrideIsTrimmed() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: ["OPENAI_API_KEY": "  sk-padded\n"]
        )
        XCTAssertEqual(store.apiKey(for: .codex), "sk-padded")
    }

    func testBlankEnvironmentValueIsIgnored() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: ["ANTHROPIC_API_KEY": "   "]
        )
        XCTAssertNil(store.apiKey(for: .claude))
    }

    func testOverrideAppliesOnlyToItsOwnReviewer() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: ["ANTHROPIC_API_KEY": "sk-anthropic"]
        )
        XCTAssertEqual(store.apiKey(for: .claude), "sk-anthropic")
        XCTAssertNil(store.apiKey(for: .codex))
    }

    func testEmptyEnvironmentFallsThroughToKeychain() {
        let store = KeychainCredentialStore(service: unusedService, environment: [:])
        // Nothing is stored under this service, so the Keychain path returns nil rather than
        // throwing or prompting.
        XCTAssertNil(store.apiKey(for: .claude))
    }

    /// Every reviewer needs an inbound variable — this is the part of the "adding a reviewer"
    /// checklist a new case is most likely to miss. The exact names are asserted in
    /// `ConfigurationAndPromptTests`; what matters here is that no two reviewers can be
    /// credentialed from the same variable and none is silently blank.
    func testEveryReviewerHasADistinctOverrideVariable() {
        let variables = ReviewerName.allCases.map(\.apiKeyOverrideEnvironmentVariable)
        XCTAssertFalse(variables.contains { $0.isEmpty })
        XCTAssertEqual(Set(variables).count, variables.count)
    }

    /// `apiKeyOverrideEnvironmentVariable` is total, so opencode names one too — but opencode is
    /// credentialed through its own config directory and has no outbound key variable, so there
    /// is nowhere for a resolved key to go. Answering with one anyway would make the settings
    /// panel report a key as "in effect" for a reviewer that never sees it.
    func testAKeyIsNotResolvedForAReviewerThatCannotBeHandedOne() {
        let store = KeychainCredentialStore(
            service: unusedService,
            environment: [
                "OPENCODE_API_KEY": "sk-opencode",
                "ANTHROPIC_API_KEY": "sk-anthropic",
            ]
        )

        XCTAssertNil(store.apiKey(for: .opencode))
        // …and the refusal is specific to opencode, not a blanket one.
        XCTAssertEqual(store.apiKey(for: .claude), "sk-anthropic")
    }

    /// The test double deliberately carries no such guard: it returns exactly what a test handed
    /// it, so a mis-wired engine fails loudly instead of being quietly papered over.
    func testTheInMemoryStoreAnswersForWhateverATestGivesIt() {
        let store = InMemoryCredentialStore(keys: [.opencode: "sk-opencode"])
        XCTAssertEqual(store.apiKey(for: .opencode), "sk-opencode")
    }

    /// The outbound variable is handed to a CLI child; the inbound one is read by Review Bot.
    /// Where both exist they must name the same variable, or a key saved in the app would be
    /// read from one name and forwarded under another.
    func testOutboundAndInboundVariablesAgreeForCLIReviewers() {
        for reviewer in ReviewerName.allCases {
            guard let outbound = reviewer.apiKeyEnvironmentVariable else { continue }
            XCTAssertEqual(outbound, reviewer.apiKeyOverrideEnvironmentVariable)
        }
    }

    func testInMemoryStoreRemovesKeyWhenSetToBlank() throws {
        let store = InMemoryCredentialStore(keys: [.claude: "sk-existing"])
        try store.setAPIKey("   ", for: .claude)
        XCTAssertNil(store.apiKey(for: .claude))
    }
}
