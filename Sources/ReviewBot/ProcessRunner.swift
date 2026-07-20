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

    /// The `PATH` every spawned command inherits. A Finder- or launch-at-login-started app
    /// inherits launchd's minimal environment (often just `/usr/bin:/bin:/usr/sbin:/sbin`),
    /// so CLIs installed by a version manager (nvm, mise, volta, fnm, asdf) are unreachable.
    /// We ask the login+interactive shell for its real `PATH` once, then fall back to a fixed
    /// list of common install dirs and the inherited value. Computed lazily, exactly once.
    static let augmentedPath: String = composePATH(
        shellPath: loginShellPATH(),
        inherited: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        home: FileManager.default.homeDirectoryForCurrentUser.path
    )

    /// Merges the login-shell `PATH` (if any), a fixed list of common install directories, and
    /// the inherited `PATH` into a single ordered, de-duplicated `PATH`. Pure so it can be tested
    /// without spawning a shell.
    static func composePATH(shellPath: String?, inherited: String, home: String) -> String {
        let preferredPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
        ]
        let ordered = (shellPath.map { [$0] } ?? []) + preferredPaths + [inherited]
        var seen = Set<String>()
        let entries = ordered
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: true).map(String.init) }
            .filter { seen.insert($0).inserted }
        return entries.joined(separator: ":")
    }

    /// Asks the user's login+interactive shell for its `PATH`, or `nil` if the probe fails.
    /// Uses `-i -l` so rc files that initialise version managers (commonly `~/.zshrc`) are sourced,
    /// wraps the shell in the same `perl alarm` timeout used for reviews so a hanging rc file can't
    /// stall startup, and emits the value behind a sentinel so a chatty rc banner can't corrupt it.
    private static func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let sentinel = "__REVIEWBOT_PATH__:"
        let script = "printf '%s%s\\n' '\(sentinel)' \"$PATH\""
        guard let output = captureStdout(
            "/usr/bin/perl",
            arguments: [
                "-e", "alarm shift @ARGV; exec @ARGV or exit 127",
                "5",
                shell, "-ilc", script,
            ]
        ) else {
            return nil
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true)
        where line.hasPrefix(sentinel) {
            let value = line.dropFirst(sentinel.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Runs a process to completion and returns its stdout, or `nil` on any failure. Reads stdout
    /// from a temp file (not a pipe) so a large rc banner can't deadlock, and discards stderr.
    private static func captureStdout(_ launchPath: String, arguments: [String]) -> String? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("review-bot-path-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? fm.removeItem(at: directory) }

        let stdoutURL = directory.appendingPathComponent("stdout")
        fm.createFile(atPath: stdoutURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: stdoutURL) else { return nil }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        try? handle.synchronize()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
    }

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
        environment["PATH"] = Self.augmentedPath
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdout = String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
        let stderr = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
        // Only the executable name is surfaced in errors and results. The argument
        // list can contain the full review prompt (plus any REVIEW.md and custom
        // instructions), which must never leak into a posted review, history, or logs.
        let displayCommand = executable

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
