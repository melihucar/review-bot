import Foundation

struct CommandResult {
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

protocol CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult
}

extension CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: nil,
            timeout: timeout
        )
    }
}

enum CommandExecutionError: LocalizedError {
    case timedOut(command: String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, seconds):
            "Command timed out after \(seconds) seconds: \(command)"
        }
    }
}

struct ProcessRunner: CommandRunning {
    private let fileManager = FileManager.default

    func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        timeout: Int = 60
    ) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            try runSynchronously(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                timeout: timeout
            )
        }.value
    }

    private func runSynchronously(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) throws -> CommandResult {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("review-bot-command-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "alarm shift @ARGV; exec @ARGV or exit 127",
            String(timeout),
            "/usr/bin/env",
            executable,
        ] + arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferredPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
        ]
        environment["PATH"] = (preferredPaths + [existingPath]).joined(separator: ":")
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdout = String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
        let stderr = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
        let displayCommand = ([executable] + arguments).joined(separator: " ")

        if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGALRM {
            throw CommandExecutionError.timedOut(command: displayCommand, seconds: timeout)
        }

        return CommandResult(
            command: displayCommand,
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}
