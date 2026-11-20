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

    func testARepositoryAddedByFolderWhileTheCloneRunsWinsAndTheCloneIsDiscarded() async throws {
        let runner = GatedRunner(gating: { $0 == "git" && $1.first == "clone" })
        let model = AppModel(
            paths: StoragePaths(root: root),
            credentials: InMemoryCredentialStore(),
            runner: runner
        )
        let adding = Task { await model.addRepository(address: "acme/widget") }
        try await runner.waitUntilGated()

        model.settings.add(
            RepositoryConfiguration(name: "widget", path: "/projects/widget", githubSlug: "acme/widget")
        )
        await runner.release()
        let added = await adding.value

        XCTAssertFalse(added)
        XCTAssertTrue(model.repositoryAdditionError?.contains("already in the list") == true)
        XCTAssertEqual(model.settings.configuration.repositories.count, 1)
        XCTAssertFalse(model.settings.configuration.repositories[0].isManaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path))
    }

    func testARepositoryRemovedDuringAPollKeepsItsCloneUntilThePollEnds() async throws {
        let runner = GatedRunner(gating: { $0 == "gh" && $1.starts(with: ["api", "user"]) })
        let model = AppModel(
            paths: StoragePaths(root: root),
            credentials: InMemoryCredentialStore(),
            runner: runner
        )
        await model.addRepository(address: "acme/widget")
        let id = try XCTUnwrap(model.settings.configuration.repositories.first?.id)

        model.runNow()
        try await runner.waitUntilGated()
        XCTAssertTrue(model.isRunning)
        await model.removeRepository(id)

        XCTAssertTrue(model.settings.configuration.repositories.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloneDirectory.path))

        await runner.release()
        for _ in 0..<500 where model.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path))
    }
}

/// Answers the commands an add or a poll makes, and holds the first one `gating` selects until
/// `release()` — which is how a test acts in the middle of an operation that is otherwise over
/// before it can.
private actor GatedRunner: CommandRunning {
    struct Timeout: Error {}

    private let gating: @Sendable (String, [String]) -> Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var isGated = false
    private var released = false

    init(gating: @escaping @Sendable (String, [String]) -> Bool) {
        self.gating = gating
    }

    func waitUntilGated() async throws {
        for _ in 0..<500 where !isGated {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard isGated else { throw Timeout() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult {
        if gating(executable, arguments), !released {
            isGated = true
            await withCheckedContinuation { continuation = $0 }
        }
        if executable == "gh", arguments.starts(with: ["api", "user"]) {
            return scriptedResult(stdout: "reviewer\n")
        }
        if executable == "gh", arguments.starts(with: ["api", "repos/acme/widget"]) {
            return scriptedResult(stdout: #"{"full_name":"acme/widget","private":false}"#)
        }
        if executable == "git", arguments.first == "clone" {
            try simulateBareClone(at: arguments.last!)
        }
        return scriptedResult()
    }
}
