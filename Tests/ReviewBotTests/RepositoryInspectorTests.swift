import Foundation
import XCTest
@testable import ReviewBot

final class RepositoryInspectorTests: XCTestCase {
    func testInspectionUsesCanonicalRootAndGitHubOrigin() async throws {
        let runner = QueueCommandRunner(results: [
            commandResult(stdout: "/projects/widget\n"),
            commandResult(stdout: "git@github.com:acme/widget.git\n"),
        ])

        let repository = try await RepositoryInspector(runner: runner).inspect(
            folder: URL(fileURLWithPath: "/projects/widget/subdirectory")
        )

        XCTAssertEqual(repository.name, "widget")
        XCTAssertEqual(repository.path, "/projects/widget")
        XCTAssertEqual(repository.githubSlug, "acme/widget")
        let invocations = await runner.recordedInvocations()
        XCTAssertEqual(invocations.map(\.executable), ["git", "git"])
        XCTAssertEqual(invocations[0].arguments.suffix(2), ["rev-parse", "--show-toplevel"])
        XCTAssertEqual(invocations[1].arguments.suffix(3), ["remote", "get-url", "origin"])
    }

    func testInspectionRejectsFolderWhenGitCommandFails() async {
        let runner = QueueCommandRunner(results: [commandResult(exitCode: 128)])

        do {
            _ = try await RepositoryInspector(runner: runner).inspect(
                folder: URL(fileURLWithPath: "/not-a-repository")
            )
            XCTFail("Expected repository inspection to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The selected folder is not a Git repository.")
        }
    }
}

private actor QueueCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private var invocations: [MockInvocation] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult {
        invocations.append(MockInvocation(executable: executable, arguments: arguments))
        return results.removeFirst()
    }

    func recordedInvocations() -> [MockInvocation] { invocations }
}

private struct MockInvocation {
    let executable: String
    let arguments: [String]
}

private func commandResult(
    exitCode: Int32 = 0,
    stdout: String = "",
    stderr: String = ""
) -> CommandResult {
    CommandResult(
        command: "mock",
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr
    )
}
