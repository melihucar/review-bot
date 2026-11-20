import Foundation
@testable import ReviewBot

/// A command that was handed to `RecordingCommandRunner`, with the environment and timeout it
/// was run with — which the environment-free `CommandRunning` overload cannot observe.
struct RecordedCommand: Equatable {
    let executable: String
    let arguments: [String]
    let environment: EnvironmentOverrides
    let timeout: Int
}

/// Answers every command through `handler` and remembers each call. It implements both `run`
/// overloads: the protocol's default for the five-argument one discards the environment, which
/// would make every environment assertion pass whatever production sent.
actor RecordingCommandRunner: CommandRunning {
    private let handler: @Sendable (String, [String]) throws -> CommandResult
    private var recorded: [RecordedCommand] = []

    init(handler: @escaping @Sendable (String, [String]) throws -> CommandResult) {
        self.handler = handler
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        timeout: Int
    ) async throws -> CommandResult {
        recorded.append(RecordedCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        ))
        return try handler(executable, arguments)
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: [:],
            timeout: timeout
        )
    }

    func commands() -> [RecordedCommand] { recorded }
}

func scriptedResult(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") -> CommandResult {
    CommandResult(command: "mock", exitCode: exitCode, stdout: stdout, stderr: stderr)
}

/// What a finished `git clone --bare` leaves at `path`, as far as `ManagedClone.isUsable` looks.
func simulateBareClone(at path: String) throws {
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("objects", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("ref: refs/heads/main\n".utf8).write(to: directory.appendingPathComponent("HEAD"))
}
