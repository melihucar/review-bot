import Foundation

struct CommandResult {
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// Review Bot ended the command itself because its output matched the caller's
    /// `stopEarly` watch — see `OutputWatch`. Never `succeeded`.
    var stoppedEarly = false

    var succeeded: Bool { exitCode == 0 && !stoppedEarly }
}

/// Called with each line a command writes (stdout and stderr alike) while it runs. Returning
/// `true` ends the command at once, and that line becomes the tail of the result's `stderr`.
///
/// This exists because a CLI can learn it will never finish and still not exit: opencode, told
/// its usage limit is exceeded, logs the error and then sits until the time limit kills it —
/// fifteen minutes per review, every review, with nothing on its streams to say why. The watch
/// lets the caller name what "never finishing" looks like and stop paying for it.
typealias OutputWatch = @Sendable (String) -> Bool

/// Changes applied on top of the inherited environment. A `nil` value removes the variable,
/// which is how a reviewer configured for session auth is kept from silently picking up an
/// API key that happens to be exported in the developer's shell.
typealias EnvironmentOverrides = [String: String?]

protocol CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult

    /// Runs a command with per-command changes applied to the process environment. A `nil`
    /// value removes the variable (see `EnvironmentOverrides`), which is how a reviewer
    /// configured for session auth is kept from inheriting an exported API key. A default
    /// implementation is provided in an extension, so mocks that only implement the
    /// environment-free variant keep working.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        timeout: Int
    ) async throws -> CommandResult

    /// As above, with an `OutputWatch` that can end the command before its time limit. The
    /// default implementation in the extension ignores the watch — so a wrapper around another
    /// runner must forward this overload explicitly, or the watch is dropped silently and a
    /// stuck reviewer waits out its whole limit again.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        stopEarly: OutputWatch?,
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

    /// Runners that do not care about the environment (test doubles, mainly) inherit this and
    /// behave exactly as they did before environment overrides existed.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            timeout: timeout
        )
    }

    /// Runners with no way to watch output (test doubles, wrappers written before the watch
    /// existed) inherit this: the command runs to completion or its limit, as before.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        stopEarly: OutputWatch?,
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            timeout: timeout
        )
    }
}

enum CommandExecutionError: LocalizedError {
    /// `detail` is the last line the command wrote before the limit fired, when there was one:
    /// a CLI that printed why it was stuck and then hung leaves that reason in the failure.
    case timedOut(command: String, seconds: Int, detail: String? = nil)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, seconds, detail):
            "Command timed out after \(seconds) seconds: \(command)"
                + (detail.map { " — \($0)" } ?? "")
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

    /// Builds the environment a child command runs under: the inherited environment, with the
    /// augmented `PATH`, a truthful `PWD`, and any per-command overrides merged over it. Pure so
    /// it can be tested without spawning anything.
    ///
    /// `PWD` is the reason this exists. Foundation sets a child's working directory through
    /// `currentDirectoryURL`, which changes the actual `getcwd()` but leaves the inherited `PWD`
    /// variable untouched — so the child is handed a shell variable that contradicts where it is
    /// really running. Most tools call `getcwd()` and never notice. `opencode` trusts `PWD`, and
    /// resolved its project root from it: a Review Bot launched from a terminal sitting in some
    /// other repository reviewed *that* repository's files while its diff and thread came from the
    /// pull request, so it produced a confident review of a codebase the PR had nothing to do with.
    /// Nothing in the output marks it as such — the verdict counts toward the panel like any other.
    ///
    /// `OLDPWD` is dropped rather than corrected: it describes a `cd` this process never made, and
    /// there is no honest value for it here.
    ///
    /// Overrides are applied last, so a caller can deliberately override even `PATH` or `PWD`. An
    /// override whose value is `nil` removes the variable outright, which is what unsets an
    /// inherited API key for a reviewer running under session auth.
    static func composeEnvironment(
        inherited: [String: String],
        path: String,
        workingDirectory: String,
        overrides: EnvironmentOverrides
    ) -> [String: String] {
        var environment = inherited
        environment["PATH"] = path
        environment["PWD"] = workingDirectory
        environment.removeValue(forKey: "OLDPWD")
        for (key, value) in overrides {
            if let value {
                environment[key] = value
            } else {
                environment.removeValue(forKey: key)
            }
        }
        return environment
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
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: [:],
            timeout: timeout
        )
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            stopEarly: nil,
            timeout: timeout
        )
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        stopEarly: OutputWatch?,
        timeout: Int
    ) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            try runSynchronously(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment,
                stopEarly: stopEarly,
                timeout: timeout
            )
        }.value
    }

    private func runSynchronously(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment overrides: EnvironmentOverrides,
        stopEarly: OutputWatch?,
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

        process.environment = Self.composeEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            path: Self.augmentedPath,
            // `currentDirectory` is what `process.currentDirectoryURL` was just set to, so the two
            // cannot drift; when it is nil the child inherits this process's own directory.
            workingDirectory: currentDirectory?.path ?? fileManager.currentDirectoryPath,
            overrides: overrides
        )

        // The watch reads the output files as the child appends to them, one new line at a
        // time, so a line is judged exactly once.
        let watcher = stopEarly.map { OutputFileWatcher(files: [stdoutURL, stderrURL], watch: $0) }
        let started = Date()

        try process.run()
        var stoppedEarly = false
        if let watcher {
            // `perl` has `exec`ed the command by now, so the pid is the CLI's own and a
            // signal reaches it directly. A polite stop first; a CLI that ignores it is
            // killed a few seconds later. The alarm still bounds the whole run.
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning, watcher.shouldStop() {
                    stoppedEarly = true
                    process.terminate()
                    var grace = 0
                    while process.isRunning, grace < 10 {
                        Thread.sleep(forTimeInterval: 0.5)
                        grace += 1
                    }
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    break
                }
            }
        }
        process.waitUntilExit()
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdout = String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
        var stderr = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
        // Only the executable name is surfaced in errors and results. The argument
        // list can contain the full review prompt (plus any REVIEW.md and custom
        // instructions), which must never leak into a posted review, history, or logs.
        let displayCommand = executable

        if !stoppedEarly, process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGALRM {
            // What the command last said is the only clue to why it hung.
            let lastLine = [stderr, stdout]
                .flatMap { $0.split(whereSeparator: \.isNewline) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            throw CommandExecutionError.timedOut(
                command: displayCommand,
                seconds: timeout,
                detail: lastLine.map { String($0.suffix(300)) }
            )
        }

        if stoppedEarly {
            // Put the reason last, where `conciseError` reads a failure from.
            let elapsed = Int(Date().timeIntervalSince(started).rounded())
            stderr += "\nStopped after \(elapsed) s: \(watcher?.matchedLine ?? "output matched the stop condition")"
        }

        return CommandResult(
            command: displayCommand,
            exitCode: stoppedEarly ? max(1, process.terminationStatus) : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            stoppedEarly: stoppedEarly
        )
    }
}

/// Feeds the lines a running command appends to its output files to an `OutputWatch`.
///
/// Keeps a read offset and a partial-line buffer per file, so each line is offered once and
/// only once it is complete. Called from the wait loop, on the thread that is waiting, so it
/// needs no locking.
final class OutputFileWatcher {
    private struct Cursor {
        var offset: UInt64 = 0
        var partial = Data()
    }

    private let files: [URL]
    private let watch: OutputWatch
    private var cursors: [Cursor]
    private(set) var matchedLine: String?

    init(files: [URL], watch: @escaping OutputWatch) {
        self.files = files
        self.watch = watch
        cursors = Array(repeating: Cursor(), count: files.count)
    }

    /// Reads whatever is new in every file and returns true as soon as a line matches.
    func shouldStop() -> Bool {
        if matchedLine != nil { return true }
        for index in files.indices {
            guard let handle = try? FileHandle(forReadingFrom: files[index]) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: cursors[index].offset)
            let data = (try? handle.readToEnd()) ?? Data()
            guard !data.isEmpty else { continue }
            cursors[index].offset += UInt64(data.count)
            var buffer = cursors[index].partial + data
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty, watch(line) {
                    matchedLine = line
                    return true
                }
            }
            cursors[index].partial = buffer
        }
        return false
    }
}
