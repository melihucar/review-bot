import XCTest
@testable import ReviewBot

final class ProcessRunnerTests: XCTestCase {
    private let home = "/Users/tester"
    private let minimalPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    func testComposePATHPrependsLoginShellPathSoVersionManagerDirsResolve() {
        let shellPath = "\(home)/.nvm/versions/node/v22.23.1/bin:/opt/homebrew/bin:\(minimalPath)"
        let composed = ProcessRunner.composePATH(
            shellPath: shellPath,
            inherited: minimalPath,
            home: home
        )
        let entries = composed.split(separator: ":").map(String.init)

        // The nvm dir from the login shell is now reachable...
        XCTAssertTrue(entries.contains("\(home)/.nvm/versions/node/v22.23.1/bin"))
        // ...and it comes before the plain system dirs that a launchd app starts with.
        let nvmIndex = entries.firstIndex(of: "\(home)/.nvm/versions/node/v22.23.1/bin")
        let usrBinIndex = entries.firstIndex(of: "/usr/bin")
        XCTAssertNotNil(nvmIndex)
        XCTAssertNotNil(usrBinIndex)
        XCTAssertLessThan(nvmIndex!, usrBinIndex!)
    }

    func testComposePATHDeduplicatesPreservingFirstOccurrence() {
        let composed = ProcessRunner.composePATH(
            shellPath: "/opt/homebrew/bin:/usr/bin",
            inherited: minimalPath,
            home: home
        )
        let entries = composed.split(separator: ":").map(String.init)

        XCTAssertEqual(entries.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertEqual(entries.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testComposePATHFallsBackToFixedListWhenNoShellPath() {
        let composed = ProcessRunner.composePATH(
            shellPath: nil,
            inherited: minimalPath,
            home: home
        )
        let entries = composed.split(separator: ":").map(String.init)

        // The original fixed install dirs are still present as a fallback.
        XCTAssertTrue(entries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(entries.contains("/usr/local/bin"))
        XCTAssertTrue(entries.contains("\(home)/.local/bin"))
        XCTAssertTrue(entries.contains("\(home)/.npm-global/bin"))
        // And the inherited system dirs remain reachable.
        XCTAssertTrue(entries.contains("/usr/bin"))
    }

    func testComposePATHIgnoresEmptySegments() {
        let composed = ProcessRunner.composePATH(
            shellPath: "::/opt/homebrew/bin::",
            inherited: minimalPath,
            home: home
        )
        let entries = composed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        XCTAssertFalse(entries.contains(""))
    }

    func testComposeEnvironmentRewritesPWDToTheChildsActualDirectory() {
        // Foundation's `currentDirectoryURL` changes the child's real `getcwd()` but leaves the
        // inherited `PWD` alone. A tool that trusts `PWD` — opencode resolves its project root
        // from it — then runs against wherever the app was launched from, and reviews that
        // codebase instead of the pull request's worktree.
        let composed = ProcessRunner.composeEnvironment(
            inherited: [
                "PATH": minimalPath,
                "PWD": "/Users/dev/review-bot",
                "OLDPWD": "/Users/dev/review-bot",
                "HOME": home,
            ],
            path: "/opt/homebrew/bin:\(minimalPath)",
            workingDirectory: "/var/reviewbot/worktrees/acme-widget/pr-42",
            overrides: [:]
        )

        XCTAssertEqual(composed["PWD"], "/var/reviewbot/worktrees/acme-widget/pr-42")
        // OLDPWD describes a `cd` this process never made; there is no honest value for it.
        XCTAssertNil(composed["OLDPWD"])
        XCTAssertEqual(composed["PATH"], "/opt/homebrew/bin:\(minimalPath)")
        // Everything else the app inherited still reaches the child.
        XCTAssertEqual(composed["HOME"], home)
    }

    func testComposeEnvironmentAppliesOverridesLast() {
        let composed = ProcessRunner.composeEnvironment(
            inherited: ["PATH": minimalPath, "OPENCODE_CONFIG_DIR": "/stale"],
            path: minimalPath,
            workingDirectory: "/work",
            overrides: [
                "OPENCODE_CONFIG_DIR": "/fresh",
                "OPENCODE_CONFIG_CONTENT": #"{"permission":{"*":"deny"}}"#,
            ]
        )

        XCTAssertEqual(composed["OPENCODE_CONFIG_DIR"], "/fresh")
        XCTAssertEqual(composed["OPENCODE_CONFIG_CONTENT"], #"{"permission":{"*":"deny"}}"#)
        XCTAssertEqual(composed["PWD"], "/work")
    }

    func testComposeEnvironmentRemovesVariablesWhoseOverrideIsNil() {
        // A reviewer configured for session auth must not inherit an API key the developer happens
        // to export in their shell: the CLI would silently bill that key instead of using the login
        // it was configured to use, with nothing in the output to say so. Merge semantics cannot
        // express that, which is why an override value is optional and `nil` means "unset".
        let composed = ProcessRunner.composeEnvironment(
            inherited: [
                "PATH": minimalPath,
                "ANTHROPIC_API_KEY": "sk-inherited-from-the-shell",
                "HOME": home,
            ],
            path: minimalPath,
            workingDirectory: "/work",
            overrides: ["ANTHROPIC_API_KEY": nil]
        )

        XCTAssertNil(composed["ANTHROPIC_API_KEY"])
        // Removing one variable leaves the rest of the inherited environment alone.
        XCTAssertEqual(composed["HOME"], home)
        XCTAssertEqual(composed["PATH"], minimalPath)
    }
}
