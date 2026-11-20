import XCTest
@testable import ReviewBot

final class ManagedCloneTests: XCTestCase {
    private var root: URL!
    private var paths: StoragePaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotManagedCloneTests-\(UUID().uuidString)", isDirectory: true)
        paths = StoragePaths(root: root)
        try paths.prepare()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func repository(
        slug: String = "acme/widget",
        transport: CloneTransport? = .https,
        path: String = "/stale/from/config"
    ) -> RepositoryConfiguration {
        RepositoryConfiguration(name: "widget", path: path, githubSlug: slug, managedClone: transport)
    }

    private var cloneDirectory: URL {
        root.appendingPathComponent("repositories/acme/widget.git", isDirectory: true)
    }

    private func succeedingRunner() -> RecordingCommandRunner {
        RecordingCommandRunner { _, arguments in
            try simulateBareClone(at: arguments.last!)
            return scriptedResult()
        }
    }

    func testHTTPSCloneUsesTheGhCredentialHelperAndNeverPrompts() async throws {
        let runner = succeedingRunner()

        _ = try await ManagedClone(paths: paths, runner: runner).ensure(repository())

        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].executable, "git")
        XCTAssertEqual(commands[0].arguments, [
            "clone", "--bare", "--quiet",
            "-c", "credential.https://github.com.helper=",
            "-c", "credential.https://github.com.helper=!gh auth git-credential",
            "--", "https://github.com/acme/widget.git",
            cloneDirectory.path + ".incoming",
        ])
        XCTAssertEqual(commands[0].environment, ["GIT_TERMINAL_PROMPT": "0"])
        XCTAssertEqual(commands[0].timeout, 1_800)
    }

    func testSSHCloneCarriesNoCredentialHelper() async throws {
        let runner = succeedingRunner()

        _ = try await ManagedClone(paths: paths, runner: runner).ensure(repository(transport: .ssh))

        let arguments = await runner.commands().first?.arguments
        XCTAssertEqual(arguments, [
            "clone", "--bare", "--quiet",
            "--", "git@github.com:acme/widget.git",
            cloneDirectory.path + ".incoming",
        ])
    }

    func testASuccessfulCloneLandsInPlaceAndIsNotRepeated() async throws {
        let runner = succeedingRunner()
        let clone = ManagedClone(paths: paths, runner: runner)

        let first = try await clone.ensure(repository())
        let second = try await clone.ensure(repository())

        XCTAssertEqual(first.directory.path, cloneDirectory.path)
        XCTAssertTrue(first.cloned)
        XCTAssertTrue(ManagedClone.isUsable(cloneDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path + ".incoming"))
        XCTAssertFalse(second.cloned)
        let count = await runner.commands().count
        XCTAssertEqual(count, 1)
    }

    func testADirectoryWithoutHeadIsClonedAgain() async throws {
        try FileManager.default.createDirectory(
            at: cloneDirectory.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true
        )
        let runner = succeedingRunner()

        let outcome = try await ManagedClone(paths: paths, runner: runner).ensure(repository())

        XCTAssertTrue(outcome.cloned)
        XCTAssertTrue(ManagedClone.isUsable(cloneDirectory))
    }

    func testAFailedCloneReportsGitsMessageAndLeavesNothingBehind() async throws {
        let runner = RecordingCommandRunner { _, arguments in
            try simulateBareClone(at: arguments.last!)
            return scriptedResult(exitCode: 128, stderr: "fatal: repository not found\n")
        }

        do {
            _ = try await ManagedClone(paths: paths, runner: runner).ensure(repository())
            XCTFail("Expected the clone to fail")
        } catch {
            XCTAssertEqual(
                error as? ManagedCloneError,
                .cloneFailed(slug: "acme/widget", transport: .https, detail: "fatal: repository not found")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path + ".incoming"))
    }

    func testATimedOutCloneIsCleanedUpToo() async throws {
        let runner = RecordingCommandRunner { _, arguments in
            try simulateBareClone(at: arguments.last!)
            throw CommandExecutionError.timedOut(command: "git clone", seconds: 1_800)
        }

        do {
            _ = try await ManagedClone(paths: paths, runner: runner).ensure(repository())
            XCTFail("Expected the clone to fail")
        } catch let error as ManagedCloneError {
            guard case let .cloneFailed(_, _, detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("timed out"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path + ".incoming"))
    }

    func testTheSSHFailureMessagePointsAtTheHTTPSAddress() {
        let message = ManagedCloneError
            .cloneFailed(slug: "acme/widget", transport: .ssh, detail: "Permission denied.")
            .errorDescription
        XCTAssertTrue(message?.contains("https:// address") == true)
        XCTAssertTrue(message?.contains("Permission denied.") == true)
    }

    func testTheDirectoryIsDerivedFromTheLowercasedSlug() {
        XCTAssertEqual(
            ManagedClone.directory(for: repository(slug: "Acme/Widget"), in: paths)?.path,
            cloneDirectory.path
        )
    }

    func testARepositoryWithAnInvalidSlugRunsNoCommand() async {
        let runner = succeedingRunner()

        do {
            _ = try await ManagedClone(paths: paths, runner: runner).ensure(repository(slug: "../../etc"))
            XCTFail("Expected an invalid repository")
        } catch {
            XCTAssertEqual(error as? ManagedCloneError, .invalidRepository("../../etc"))
        }
        let count = await runner.commands().count
        XCTAssertEqual(count, 0)
    }

    func testRemovalDeletesTheDerivedCloneNeverTheConfiguredPath() throws {
        try simulateBareClone(at: cloneDirectory.path)
        let decoy = root.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        let runner = succeedingRunner()

        ManagedClone(paths: paths, runner: runner).remove(repository(path: decoy.path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneDirectory.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoy.path))
    }

    func testRemovalLeavesAnOwnerDirectoryThatStillHoldsAnotherClone() throws {
        try simulateBareClone(at: cloneDirectory.path)
        let sibling = cloneDirectory.deletingLastPathComponent().appendingPathComponent("other.git")
        try simulateBareClone(at: sibling.path)

        ManagedClone(paths: paths, runner: succeedingRunner()).remove(repository())

        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testRemovalNeverWipesASiblingsIncomingClone() throws {
        try simulateBareClone(at: cloneDirectory.path)
        let incoming = cloneDirectory.deletingLastPathComponent().appendingPathComponent("other.git.incoming")
        try simulateBareClone(at: incoming.path)

        ManagedClone(paths: paths, runner: succeedingRunner()).remove(repository())

        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path))
    }

    func testAFolderRepositoryHasNoManagedDirectory() {
        XCTAssertNil(ManagedClone.directory(for: repository(transport: nil), in: paths))
    }
}
