import XCTest
@testable import ReviewBot

@MainActor
final class AppModelRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotAppModelTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var cloneDirectory: URL {
        root.appendingPathComponent("repositories/acme/widget.git", isDirectory: true)
    }

    private func model(
        gh: CommandResult = scriptedResult(
            stdout: #"{"full_name":"Acme/Widget","private":true,"permissions":{"admin":false,"maintain":false,"push":true,"triage":true,"pull":true}}"#
        ),
        cloneExitCode: Int32 = 0
    ) -> (AppModel, RecordingCommandRunner) {
        let runner = RecordingCommandRunner { executable, arguments in
            if executable == "gh" { return gh }
            if executable == "git", arguments.first == "clone" {
                guard cloneExitCode == 0 else {
                    return scriptedResult(exitCode: cloneExitCode, stderr: "fatal: could not read from remote")
                }
                try simulateBareClone(at: arguments.last!)
                return scriptedResult()
            }
            return scriptedResult()
        }
        let model = AppModel(
            paths: StoragePaths(root: root),
            credentials: InMemoryCredentialStore(),
            runner: runner
        )
        return (model, runner)
    }

    func testAddingByAddressChecksAccessClonesAndRecordsTheRepository() async throws {
        let (model, runner) = model()

        let added = await model.addRepository(address: "https://github.com/acme/widget")

        XCTAssertTrue(added)
        let repository = try XCTUnwrap(model.settings.configuration.repositories.first)
        XCTAssertEqual(model.settings.configuration.repositories.count, 1)
        XCTAssertEqual(repository.githubSlug, "Acme/Widget")
        XCTAssertEqual(repository.managedClone, .https)
        XCTAssertTrue(repository.isManaged)
        XCTAssertTrue(ManagedClone.isUsable(cloneDirectory))
        XCTAssertNil(model.repositoryAdditionError)
        XCTAssertNil(model.repositoryAdditionProgress)
        XCTAssertTrue(model.status.contains("write access"))
        let commands = await runner.commands()
        XCTAssertEqual(commands.map(\.executable), ["gh", "git"])
    }

    func testAddingTheSameAddressAgainIsRefusedWithoutRunningAnything() async {
        let (model, runner) = model()
        await model.addRepository(address: "https://github.com/acme/widget")
        let before = await runner.commands().count

        let added = await model.addRepository(address: "git@github.com:ACME/widget.git")

        XCTAssertFalse(added)
        XCTAssertTrue(model.repositoryAdditionError?.contains("already in the list") == true)
        XCTAssertEqual(model.settings.configuration.repositories.count, 1)
        let after = await runner.commands().count
        XCTAssertEqual(after, before)
    }

    func testARepositoryGitHubCannotShowIsNotAdded() async {
        let (model, runner) = model(
            gh: scriptedResult(exitCode: 1, stdout: #"{"message":"Not Found"}"#, stderr: "gh: Not Found (HTTP 404)")
        )

        let added = await model.addRepository(address: "acme/widget")

        XCTAssertFalse(added)
        XCTAssertEqual(model.repositoryAdditionError, RepositoryAccessError.notFound("acme/widget").errorDescription)
        XCTAssertTrue(model.settings.configuration.repositories.isEmpty)
        let commands = await runner.commands()
        XCTAssertFalse(commands.contains { $0.arguments.first == "clone" })
    }

    func testAFailedCloneAddsNothing() async {
        let (model, _) = model(cloneExitCode: 128)

        let added = await model.addRepository(address: "acme/widget")

        XCTAssertFalse(added)
        XCTAssertTrue(model.repositoryAdditionError?.contains("Could not clone Acme/Widget over HTTPS") == true)
        XCTAssertTrue(model.settings.configuration.repositories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path))
    }

    func testAMalformedAddressRunsNoCommand() async {
        let (model, runner) = model()

        let added = await model.addRepository(address: "https://gitlab.com/acme/widget")

        XCTAssertFalse(added)
        XCTAssertEqual(
            model.repositoryAdditionError,
            RepositoryAddressError.unsupportedHost("gitlab.com").errorDescription
        )
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testRemovingAManagedRepositoryDeletesItsClone() async throws {
        let (model, _) = model()
        await model.addRepository(address: "acme/widget")
        let id = try XCTUnwrap(model.settings.configuration.repositories.first?.id)

        await model.removeRepository(id)

        XCTAssertTrue(model.settings.configuration.repositories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path))
    }
}
