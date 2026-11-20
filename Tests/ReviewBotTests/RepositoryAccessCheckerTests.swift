import XCTest
@testable import ReviewBot

final class RepositoryAccessCheckerTests: XCTestCase {
    private func access(
        _ typed: String = "acme/widget",
        transport: CloneTransport = .https,
        answering result: CommandResult
    ) async throws -> (RepositoryAccess, [RecordedCommand]) {
        let runner = RecordingCommandRunner { _, _ in result }
        let address = try XCTUnwrap(GitHubRepositoryAddress(slug: typed, transport: transport))
        let access = try await RepositoryAccessChecker(runner: runner).check(address)
        return (access, await runner.commands())
    }

    private func failure(
        _ result: CommandResult,
        slug: String = "acme/widget"
    ) async -> RepositoryAccessError? {
        do {
            _ = try await access(slug, answering: result)
            XCTFail("Expected the access check to fail")
            return nil
        } catch {
            return error as? RepositoryAccessError
        }
    }

    private func body(_ flags: String) -> CommandResult {
        scriptedResult(stdout: #"{"full_name":"acme/widget","private":true,"permissions":\#(flags)}"#)
    }

    func testReadOnlyAccessIsReadAndAsksGitHubForExactlyTheRepository() async throws {
        let (result, commands) = try await access(
            "cli/cli",
            answering: scriptedResult(
                stdout: #"{"full_name":"cli/cli","private":false,"permissions":{"admin":false,"maintain":false,"pull":true,"push":false,"triage":false}}"#
            )
        )

        XCTAssertEqual(result.permission, .read)
        XCTAssertFalse(result.isPrivate)
        XCTAssertEqual(result.address.slug, "cli/cli")
        XCTAssertEqual(commands.map(\.executable), ["gh"])
        XCTAssertEqual(commands.first?.arguments, ["api", "repos/cli/cli"])
    }

    func testTheHighestPermissionWins() async throws {
        let cases: [(String, RepositoryPermission)] = [
            (#"{"admin":true,"maintain":true,"push":true,"triage":true,"pull":true}"#, .admin),
            (#"{"admin":false,"maintain":true,"push":true,"triage":true,"pull":true}"#, .maintain),
            (#"{"admin":false,"maintain":false,"push":true,"triage":true,"pull":true}"#, .write),
            (#"{"admin":false,"maintain":false,"push":false,"triage":true,"pull":true}"#, .triage),
        ]
        for (flags, expected) in cases {
            let (result, _) = try await access(answering: body(flags))
            XCTAssertEqual(result.permission, expected, flags)
            XCTAssertTrue(result.isPrivate)
        }
    }

    func testGitHubsCanonicalNameReplacesTheTypedOneAndKeepsTheTransport() async throws {
        let (result, _) = try await access(
            "acme/widget",
            transport: .ssh,
            answering: scriptedResult(stdout: #"{"full_name":"Acme/Widget-Renamed","private":false}"#)
        )

        XCTAssertEqual(result.address.slug, "Acme/Widget-Renamed")
        XCTAssertEqual(result.address.transport, .ssh)
    }

    func testAMissingPermissionsObjectStillProvesReadAccess() async throws {
        let (result, _) = try await access(
            answering: scriptedResult(stdout: #"{"full_name":"acme/widget","private":false}"#)
        )
        XCTAssertEqual(result.permission, .read)
    }

    func testNoPermissionFlagsAtAllIsForbidden() async {
        let error = await failure(body(#"{"admin":false,"maintain":false,"push":false,"triage":false,"pull":false}"#))
        guard case .forbidden = error else { return XCTFail("Expected forbidden, got \(String(describing: error))") }
    }

    func testANotFoundResponseNamesTheRepository() async {
        let error = await failure(scriptedResult(
            exitCode: 1,
            stdout: #"{"message":"Not Found","status":"404"}"#,
            stderr: "gh: Not Found (HTTP 404)"
        ))
        XCTAssertEqual(error, .notFound("acme/widget"))
        XCTAssertTrue(error?.errorDescription?.contains("acme/widget") == true)
    }

    func testAuthenticationProblemsAreRecognized() async {
        let exitFour = await failure(scriptedResult(exitCode: 4, stderr: "To get started with GitHub CLI"))
        let loginHint = await failure(scriptedResult(exitCode: 1, stderr: "Run gh auth login to authenticate"))
        let badCredentials = await failure(scriptedResult(exitCode: 1, stderr: "gh: Bad credentials (HTTP 401)"))
        XCTAssertEqual(exitFour, .notAuthenticated)
        XCTAssertEqual(loginHint, .notAuthenticated)
        XCTAssertEqual(badCredentials, .notAuthenticated)
    }

    func testAForbiddenResponseCarriesGitHubsOwnExplanation() async throws {
        let error = await failure(scriptedResult(
            exitCode: 1,
            stderr: "gh: Resource protected by organization SAML enforcement. (HTTP 403)"
        ))
        guard case let .forbidden(slug, detail) = error else {
            return XCTFail("Expected forbidden, got \(String(describing: error))")
        }
        XCTAssertEqual(slug, "acme/widget")
        XCTAssertTrue(detail.contains("SAML enforcement"))
    }

    func testAMissingGitHubCLIIsRecognized() async {
        let error = await failure(scriptedResult(exitCode: 127, stderr: "env: gh: No such file or directory"))
        XCTAssertEqual(error, .githubCLIMissing)
    }

    func testAnythingElseIsAFailureWithItsDetail() async {
        let error = await failure(scriptedResult(exitCode: 1, stderr: "error connecting to api.github.com"))
        guard case let .failed(_, detail) = error else {
            return XCTFail("Expected failed, got \(String(describing: error))")
        }
        XCTAssertTrue(detail.contains("api.github.com"))
    }

    func testAnUndecodableSuccessIsAnUnexpectedResponse() async {
        let error = await failure(scriptedResult(stdout: "not json"))
        XCTAssertEqual(error, .unexpectedResponse("acme/widget"))
    }

    func testEveryErrorExplainsItself() {
        let errors: [RepositoryAccessError] = [
            .githubCLIMissing,
            .notAuthenticated,
            .notFound("acme/widget"),
            .forbidden(slug: "acme/widget", detail: "no"),
            .failed(slug: "acme/widget", detail: "no"),
            .unexpectedResponse("acme/widget"),
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
        XCTAssertTrue(errors.dropFirst(2).allSatisfy { $0.errorDescription?.contains("acme/widget") == true })
    }
}
