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

    /// Runs a command with extra environment variables merged over the process
    /// environment. A default implementation is provided in an extension, so
    /// mocks that only implement the environment-free variant keep working.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int,
        environment: [String: String]?
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

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int,
        environment: [String: String]?
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
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
    // Keep the deadline in a supervisor: exec'ing a launcher only times out the launcher,
    // and an exec'ed program can cancel an inherited alarm. Each invocation owns a process
    // group so timeout cleanup also reaches reviewer binaries and their helper processes.
    private static let supervisedCommand = #"""
    use POSIX qw(setpgid);
    my $timeout = shift @ARGV;
    my $pid = fork();
    defined $pid or die "fork failed: $!";
    if ($pid == 0) {
        setpgid(0, 0) == 0 or die "setpgid failed: $!";
        exec @ARGV;
        exit 127;
    }
    setpgid($pid, $pid);
    my $stop = sub {
        my ($signal) = @_;
        alarm 0;
        kill 'TERM', -$pid;
        select undef, undef, undef, 0.2;
        kill 'KILL', -$pid;
        # Also cover a child that has not reached setpgid yet.
        kill 'KILL', $pid;
        waitpid($pid, 0);
        $SIG{$signal} = 'DEFAULT';
        kill $signal, $$;
        exit 125;
    };
    $SIG{ALRM} = sub { $stop->('ALRM') };
    $SIG{TERM} = sub { $stop->('TERM') };
    $SIG{INT} = sub { $stop->('INT') };
    $SIG{HUP} = sub { $stop->('HUP') };
    alarm $timeout;
    my $waited;
    do { $waited = waitpid($pid, 0) } while ($waited == -1 && $!{EINTR});
    my $status = $?;
    alarm 0;
    exit 127 if $waited == -1;
    if (my $signal = $status & 127) {
        $SIG{$_} = 'DEFAULT' for qw(ALRM TERM INT HUP);
        kill $signal, $$;
        exit 125;
    }
    exit($status >> 8);
    """#

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
    static func composeEnvironment(
        inherited: [String: String],
        path: String,
        workingDirectory: String,
        overrides: [String: String]?
    ) -> [String: String] {
        var environment = inherited
        environment["PATH"] = path
        environment["PWD"] = workingDirectory
        environment.removeValue(forKey: "OLDPWD")
        for (key, value) in overrides ?? [:] {
            environment[key] = value
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
            timeout: timeout,
            environment: nil
        )
    }

    func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        timeout: Int = 60,
        environment: [String: String]?
    ) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            try runSynchronously(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                timeout: timeout,
                environmentOverrides: environment
            )
        }.value
    }

    private func runSynchronously(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int,
        environmentOverrides: [String: String]? = nil
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
            Self.supervisedCommand,
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
            overrides: environmentOverrides
        )

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
