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
        // opencode is new, opt-in, and defaults to the free flash model at max effort.
        XCTAssertFalse(configuration.opencode.enabled)
        XCTAssertEqual(configuration.opencode.model, "opencode/deepseek-v4-flash-free")
        XCTAssertEqual(configuration.opencode.effort, .max)
    }

    func testOpencodeConfigurationDecodesAndClampsEffortToMax() throws {
        let json = #"""
        {
          "repositories": [],
          "opencode": { "enabled": true, "model": "opencode/deepseek-v4-flash-free", "effort": "xhigh" }
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        // opencode's CLI accepts low/medium/high/max, so xhigh falls back to max.
        XCTAssertTrue(configuration.opencode.enabled)
        XCTAssertEqual(configuration.opencode.effort, .max)
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

    func testConfigurationWithoutAuthModeDefaultsToSessionAndDisabledDeepSeek() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "customPrompt": ""
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(configuration.claude.authMode, .session)
        XCTAssertEqual(configuration.codex.authMode, .session)
        XCTAssertFalse(configuration.deepseek.enabled)
        XCTAssertEqual(configuration.deepseek.model, "deepseek-chat")
        XCTAssertEqual(configuration.enabledReviewers.map(\.name), [.claude])
    }

    func testOpencodeIsAlwaysSessionAuthEvenIfConfigSaysOtherwise() throws {
        let json = #"""
        {
          "repositories": [],
          "opencode": {
            "enabled": true, "model": "opencode/deepseek-v4-flash-free", "effort": "max",
            "authMode": "apiKey"
          }
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        // The mirror image of the DeepSeek rule below. opencode authenticates through its own
        // config directory and reads no key variable, so `environmentOverrides` would inject
        // nothing while `meteredUsage` started counting it as billed to the developer's key.
        XCTAssertEqual(configuration.opencode.authMode, .session)
        XCTAssertFalse(ReviewerName.opencode.supportsAPIKeyAuth)
    }

    /// Adding `ReviewerConfiguration.init(from:)` for `authMode` made every other key optional
    /// too, so a reviewer object that omits `model` now loads instead of throwing the file away
    /// and falling back to `.default`. That is the right trade — but an empty model is not
    /// runnable, so it has to be filled in rather than carried into `--model ""`.
    func testAReviewerWithNoModelFallsBackToTheShippedDefault() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true },
          "codex": { "enabled": true, "model": "   ", "effort": "high" }
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(configuration.claude.model, ReviewBotConfiguration.default.claude.model)
        XCTAssertEqual(configuration.codex.model, ReviewBotConfiguration.default.codex.model)
        // The rest of the defensive decoding is unchanged: what was present is kept.
        XCTAssertTrue(configuration.claude.enabled)
        XCTAssertEqual(configuration.claude.effort, .high)
    }

    func testDeepSeekAlwaysUsesAPIKeyAuthEvenIfConfigSaysOtherwise() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": false, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "deepseek": { "enabled": true, "model": "deepseek-chat", "effort": "high", "authMode": "session" },
          "customPrompt": ""
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        // There is no DeepSeek CLI to borrow a session from.
        XCTAssertEqual(configuration.deepseek.authMode, .apiKey)
        XCTAssertEqual(configuration.enabledReviewers.map(\.name), [.deepseek])
    }

    func testAuthModeRoundTripsAndConfigurationNeverCarriesTheKey() throws {
        var configuration = ReviewBotConfiguration.default
        configuration.claude.authMode = .apiKey

        let encoder = JSONEncoder()
        let data = try encoder.encode(configuration)
        let json = String(decoding: data, as: UTF8.self)

        // Keys live in the Keychain; the config file must only record which source to use.
        XCTAssertTrue(json.contains("\"authMode\":\"apiKey\""))
        XCTAssertFalse(json.lowercased().contains("\"apikey\":\""))
        XCTAssertFalse(json.lowercased().contains("secret"))

        let decoded = try JSONDecoder().decode(ReviewBotConfiguration.self, from: data)
        XCTAssertEqual(decoded.claude.authMode, .apiKey)
        XCTAssertEqual(decoded.codex.authMode, .session)
    }

    func testEnabledReviewersKeepAStableOrder() {
        var configuration = ReviewBotConfiguration.default
        configuration.claude.enabled = true
        configuration.codex.enabled = true
        configuration.opencode.enabled = true
        configuration.deepseek.enabled = true

        // This order is `ReviewerName`'s declaration order, and it is load-bearing twice over: it
        // fixes the order the panels appear in the posted review, and it is the order
        // `runReconciliation` walks when picking an adjudicator. DeepSeek is last so the one
        // reviewer that always bills a key never adjudicates while a CLI is available.
        XCTAssertEqual(
            configuration.enabledReviewers.map(\.name),
            [.claude, .codex, .opencode, .deepseek]
        )
        XCTAssertEqual(configuration.enabledReviewers.map(\.name), ReviewerName.allCases)

        // Disabling one reviewer removes it without disturbing the order of the rest.
        configuration.codex.enabled = false
        XCTAssertEqual(
            configuration.enabledReviewers.map(\.name),
            [.claude, .opencode, .deepseek]
        )
    }

    func testSettingsLookupReturnsEachReviewersOwnConfiguration() {
        // `settings(for:)` is a four-arm switch over identically typed properties, so a
        // copy-paste there would hand one reviewer another's model, effort, and auth mode with
        // nothing to catch it. `enabledReviewers` is built on top of it.
        var configuration = ReviewBotConfiguration.default
        configuration.claude.model = "model-claude"
        configuration.codex.model = "model-codex"
        configuration.opencode.model = "model-opencode"
        configuration.deepseek.model = "model-deepseek"

        for reviewer in ReviewerName.allCases {
            XCTAssertEqual(
                configuration.settings(for: reviewer).model,
                "model-\(reviewer.rawValue.lowercased())",
                "\(reviewer.rawValue) reads another reviewer's configuration"
            )
        }
    }

    /// The "adding a reviewer" checklist, as assertions. Every one of these is a total switch
    /// over `ReviewerName`, so a new case compiles only once each has an arm — but nothing makes
    /// that arm *correct*, and several of them were written when there were two reviewers and
    /// answered by accident for the third and fourth.
    func testEveryReviewerDeclaresACoherentCredentialAndUsageSurface() {
        XCTAssertEqual(ReviewerName.allCases.map(\.commandName), [
            "claude",
            "codex",
            "opencode",
            nil,
        ])
        XCTAssertEqual(ReviewerName.allCases.map(\.apiKeyEnvironmentVariable), [
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            nil,
            nil,
        ])
        // Inbound: what Review Bot itself reads a key from, ahead of the Keychain. Total, so it
        // names one even for opencode, which never consults it.
        XCTAssertEqual(ReviewerName.allCases.map(\.apiKeyOverrideEnvironmentVariable), [
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "OPENCODE_API_KEY",
            "DEEPSEEK_API_KEY",
        ])
        let inbound = ReviewerName.allCases.map(\.apiKeyOverrideEnvironmentVariable)
        XCTAssertEqual(Set(inbound).count, inbound.count, "two reviewers would share a key")

        // Only a CLI can borrow a login; only a reviewer Review Bot can hand a key to may be put
        // in key mode. opencode is the one reviewer that is neither, which is why it needs both
        // predicates rather than one.
        XCTAssertEqual(ReviewerName.allCases.map(\.supportsSessionAuth), [true, true, true, false])
        XCTAssertEqual(ReviewerName.allCases.map(\.supportsAPIKeyAuth), [true, true, false, true])
        XCTAssertFalse(
            ReviewerName.allCases.contains { !$0.supportsSessionAuth && !$0.supportsAPIKeyAuth },
            "a reviewer with neither auth mode could never be credentialed at all"
        )

        // Claude's CLI prints a usage envelope and DeepSeek's API reports tokens; Codex and
        // opencode print the review and nothing else, so claiming otherwise would promise the
        // usage report a figure nothing collects.
        XCTAssertEqual(ReviewerName.allCases.map(\.reportsTokenUsage), [true, false, false, true])
        XCTAssertEqual(ReviewerName.allCases.map(\.usesEffortSetting), [true, true, true, false])

        for reviewer in ReviewerName.allCases {
            XCTAssertEqual(
                reviewer.efforts.isEmpty,
                !reviewer.usesEffortSetting,
                "\(reviewer.rawValue) offers effort levels it does not use, or none it does"
            )
            XCTAssertFalse(reviewer.symbolName.isEmpty)
        }
    }

    func testTokenSummaryTreatsCachedTokensAsASubsetOfInput() {
        // `inputTokens` holds the uncached portion, so a summary that printed it as "in" while
        // listing the cached count beside it understated the real input by the cached amount.
        let usage = TokenUsage(
            inputTokens: 28_033,
            cachedInputTokens: 18_688,
            outputTokens: 2_898,
            requests: 12
        )

        XCTAssertEqual(usage.totalInputTokens, 46_721)
        XCTAssertEqual(usage.totalTokens, 49_619)
        XCTAssertEqual(usage.tokenSummary, "46.7k in (18.7k cached) + 2.9k out over 12 calls")
    }

    func testTokenSummaryOmitsCacheAndCallCountWhenThereIsNothingToSay() {
        let usage = TokenUsage(inputTokens: 900, outputTokens: 120, requests: 1)
        XCTAssertEqual(usage.tokenSummary, "900 in + 120 out")
    }

    func testUsageAddsUpAndKeepsAnUnknownCostUnknown() {
        let priced = TokenUsage(inputTokens: 10, outputTokens: 5, requests: 1, costUSD: 0.25)
        let unpriced = TokenUsage(inputTokens: 20, outputTokens: 7, requests: 1)

        let both = priced + unpriced
        XCTAssertEqual(both.inputTokens, 30)
        XCTAssertEqual(both.outputTokens, 12)
        XCTAssertEqual(both.requests, 2)
        XCTAssertEqual(both.costUSD, 0.25, "a reviewer with no price must not zero out a known cost")

        let neither = unpriced + unpriced
        XCTAssertNil(neither.costUSD, "two unknowns must stay unknown, not become $0.00")
    }

    func testCostFormattingKeepsSmallAmountsLegible() {
        XCTAssertEqual(TokenUsage(costUSD: 0.006453).costSummary, "$0.0065")
        XCTAssertEqual(TokenUsage(costUSD: 12.5).costSummary, "$12.50")
        XCTAssertNil(TokenUsage().costSummary)
    }

    func testUsageSettingDefaultsOnAndSurvivesOlderConfigurations() throws {
        let json = #"""
        {
          "repositories": [],
          "claude": { "enabled": true, "model": "claude", "effort": "high" },
          "codex": { "enabled": false, "model": "codex", "effort": "medium" },
          "customPrompt": ""
        }
        """#

        let configuration = try JSONDecoder().decode(
            ReviewBotConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(configuration.includeUsageInReview)
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

    func testFailureBudgetDecodesWithABoundedDefault() throws {
        XCTAssertEqual(ReviewBotConfiguration.default.failureBudget, .attempts(5))

        // A config written before the setting existed adopts the bounded default…
        let legacy = Data(#"{"pollIntervalMinutes":15}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ReviewBotConfiguration.self, from: legacy).failureBudget,
            .attempts(5)
        )

        // …while zero means the user turned the budget off, and survives a save.
        let off = Data(#"{"failureBudget":0}"#.utf8)
        let unlimited = try JSONDecoder().decode(ReviewBotConfiguration.self, from: off)
        XCTAssertEqual(unlimited.failureBudget, .unlimited)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ReviewBotConfiguration.self,
                from: try JSONEncoder().encode(unlimited)
            ),
            unlimited
        )

        XCTAssertEqual(FailureBudget(limit: 0), .attempts(1))
        XCTAssertEqual(FailureBudget(limit: nil), .unlimited)
    }

    func testReviewAttemptStoreCountsFailuresAndClearsThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotAttempts-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(root: root)
        try paths.prepare()

        let now = Date()
        let store = ReviewAttemptStore(paths: paths, now: now)
        XCTAssertNil(store.attempt(for: "acme/widget#42@head@marker"))
        XCTAssertEqual(store.recordFailure(for: "acme/widget#42@head@marker", at: now), 1)
        XCTAssertEqual(store.recordFailure(for: "acme/widget#42@head@marker", at: now), 2)

        // A fresh store reloads the count and the timestamp from disk.
        let reloaded = ReviewAttemptStore(paths: paths, now: now)
        let attempt = try XCTUnwrap(reloaded.attempt(for: "acme/widget#42@head@marker"))
        XCTAssertEqual(attempt.failures, 2)
        XCTAssertEqual(attempt.lastAttempt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)

        reloaded.clear("acme/widget#42@head@marker", at: now)
        XCTAssertNil(ReviewAttemptStore(paths: paths, now: now).attempt(for: "acme/widget#42@head@marker"))
    }

    func testReviewAttemptStoreDropsEntriesPastRetention() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotAttempts-\(UUID().uuidString)", isDirectory: true)
        let paths = StoragePaths(root: root)
        try paths.prepare()

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ReviewAttemptStore(paths: paths, now: old)
        store.recordFailure(for: "acme/widget#1@head@marker", at: old)

        // Loading past the retention window forgets the stale entry.
        let reloaded = ReviewAttemptStore(
            paths: paths,
            now: old.addingTimeInterval(ReviewAttemptStore.retention + 60)
        )
        XCTAssertNil(reloaded.attempt(for: "acme/widget#1@head@marker"))
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

    /// `finalReviewRequest` restates the output contract — including a `## Merge gate` section and
    /// the severity rules — at the moment DeepSeek is asked for its answer. A chat model routinely
    /// echoes a chunk of that back inside the review it writes, and `InjectionGuard` downgrades an
    /// approval whose own prose describes a merge blocker. Instruction text that trips that check
    /// would turn every legitimate DeepSeek approval into a neutral comment, with no reviewer at
    /// fault and nothing in the logs pointing here.
    func testTheFinalReviewRequestCannotDowngradeAnApprovalIfTheModelEchoesIt() {
        let echoed = """
        ## Summary
        The change is safe.

        ## Findings
        Blocking: None. Should-fix: None. Nit: None.

        ## Merge gate
        Mergeable as-is.

        \(DefaultPrompt.finalReviewRequest)

        VERDICT: CLEAN
        """
        let result = ReviewerResult(
            reviewer: .deepseek,
            model: "deepseek-chat",
            output: echoed,
            verdict: .clean,
            failure: nil
        )

        XCTAssertNil(
            InjectionGuard.flagIfApproveUnsafe(
                thread: "PR conversation, nothing planted",
                diff: "diff --git a/a.swift b/a.swift\n+let x = 1\n",
                results: [result],
                adjudication: nil
            ),
            "the restated contract must not read as the reviewer calling the PR unmergeable"
        )
    }

    func testReconciliationMakesADowngradeJustifyItself() {
        let prompt = DefaultPrompt.reconciliation(reviews: [
            (reviewer: "Claude", body: "## Findings\nShould-fix: the count is wrong.", verdict: "SHOULD_FIX"),
            (reviewer: "Codex", body: "## Findings\nNone.", verdict: "CLEAN"),
        ])

        // Both reviews reach the adjudicator verbatim, tagged with who said what.
        XCTAssertTrue(prompt.contains("--- BEGIN Claude REVIEW (verdict: SHOULD_FIX) ---"))
        XCTAssertTrue(prompt.contains("--- BEGIN Codex REVIEW (verdict: CLEAN) ---"))
        XCTAssertTrue(prompt.contains("the count is wrong."))

        // A finding that survives substantiation and scope can still be reduced, but only
        // by naming what it actually costs — "polish" is the conclusion, not the argument.
        XCTAssertTrue(prompt.contains("Severity moves in both directions"))
        XCTAssertTrue(prompt.contains("is not a justification on its own"))
        XCTAssertTrue(prompt.contains("the finding stands at the severity it was given"))
        // And the adjudicator is not confined to loosening.
        XCTAssertTrue(prompt.contains("warrants a *higher* severity"))

        XCTAssertTrue(prompt.hasSuffix("VERDICT: <BLOCKING | SHOULD_FIX | NITS_ONLY | CLEAN>"))
    }

    func testReconciliationDoesNotAssumeExactlyTwoReviewers() {
        // The panel is however many reviewers are enabled. The prompt used to say "two" three
        // times over, so a third enabled reviewer handed the adjudicator a document that
        // miscounted its own contents and told it to weigh "the stricter one" of three.
        let prompt = DefaultPrompt.reconciliation(reviews: [
            (reviewer: "Claude", body: "Should-fix: the count is wrong.", verdict: "SHOULD_FIX"),
            (reviewer: "Codex", body: "None.", verdict: "CLEAN"),
            (reviewer: "opencode", body: "Blocking: unsafe cast.", verdict: "BLOCKING"),
        ])

        for reviewer in ["Claude", "Codex", "opencode"] {
            XCTAssertTrue(prompt.contains("--- BEGIN \(reviewer) REVIEW"), "\(reviewer) is missing")
        }
        XCTAssertFalse(prompt.contains("two independent"))
        XCTAssertFalse(prompt.contains("the two reviews"))
        XCTAssertFalse(prompt.contains("average the two"))
        XCTAssertFalse(prompt.contains("a finding both raised"))

        // Counting reviewers is not evidence: the panel mixes models of very different capability,
        // so agreement between two weak reviewers must not outweigh one strong dissent.
        XCTAssertTrue(prompt.contains("counting them measures the panel rather than the code"))

        // Two of three verdicts clear the gate here. The adjudicator must not read that as a
        // majority, nor read a name's absence as assent.
        XCTAssertTrue(prompt.contains("do not average them, and do not defer to the strictest by default"))
        XCTAssertTrue(prompt.contains("absence of evidence, not agreement"))
    }
}
