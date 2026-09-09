import XCTest
@testable import ReviewBot

final class ProcessRunnerTests: XCTestCase {
    func testTimeoutStopsDescendantsEvenWhenTheyIgnoreTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("orphan-finished")
        let script = #"if (fork() == 0) { $SIG{TERM} = 'IGNORE'; sleep 2; open(my $f, '>', $ARGV[0]) or die $!; print $f 'orphan'; exit 0; } sleep 5;"#
        do {
            _ = try await ProcessRunner().run("/usr/bin/perl", arguments: ["-e", script, marker.path], timeout: 1)
            XCTFail("Expected timeout")
        } catch let error as CommandExecutionError {
            guard case .timedOut(_, 1) = error else { return XCTFail("Wrong timeout") }
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A timed-out review must not continue in an orphaned child")
    }

    func testChildCannotDisableTheDeadline() async throws {
        _ = ProcessRunner.augmentedPath // Exclude one-time login-shell discovery from the deadline.
        let started = Date()
        do {
            _ = try await ProcessRunner().run("/usr/bin/perl", arguments: ["-e", "alarm 0; sleep 3;"], timeout: 1)
            XCTFail("A child cancelling its own alarm must not cancel the runner deadline")
        } catch is CommandExecutionError { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testChildSignalIsPreserved() async throws {
        let result = try await ProcessRunner().run("/usr/bin/perl", arguments: ["-e", "kill 'TERM', $$;"], timeout: 5)
        XCTAssertEqual(result.exitCode, 15)
        XCTAssertFalse(result.succeeded)
    }

    func testNormalExitCodeAndOutputArePreserved() async throws {
        let result = try await ProcessRunner().run("/usr/bin/perl", arguments: ["-e", "print 'out'; print STDERR 'err'; exit 124;"], timeout: 5)
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
    }

    func testTimeoutDoesNotKillAnotherConcurrentCommand() async throws {
        async let survivor = ProcessRunner().run("/usr/bin/perl", arguments: ["-e", "sleep 2; print 'survived';"], timeout: 5)
        do {
            _ = try await ProcessRunner().run("/usr/bin/perl", arguments: ["-e", "sleep 5;"], timeout: 1)
            XCTFail("Expected timeout")
        } catch is CommandExecutionError { }
        let result = try await survivor
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "survived")
    }

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
            overrides: nil
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
}
