import Foundation

/// Read-only file access for the DeepSeek reviewer, confined to a single review worktree.
///
/// The CLI reviewers get their sandbox from the CLI itself (`claude --allowedTools Read Grep
/// Glob`, `codex -s read-only`). DeepSeek is reached over HTTP, so the equivalent guarantee has
/// to be enforced here: every path a tool call names is resolved and rejected unless it stays
/// inside the worktree, and nothing writes, executes, or reaches the network.
struct WorktreeTools {
    /// Guard rails so a runaway tool loop cannot exhaust the model's context.
    private enum Limits {
        /// The ceiling on holding a whole file in memory — not on serving it. `read_file` pages
        /// with `offset`/`limit` and `search` matches line by line, so anything under this is
        /// readable a piece at a time however big it is. It exists only so a stray multi-gigabyte
        /// artefact in a worktree cannot exhaust memory.
        static let maxLoadableBytes = 64_000_000
        static let maxReadLines = 600
        static let maxOutputCharacters = 40_000
        static let maxSearchResults = 60
        static let maxSearchedFiles = 4_000
        static let maxListedEntries = 300
    }

    private let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        // Resolve once: temporary directories are symlinked on macOS (`/var` → `/private/var`),
        // and containment has to be checked against the real path on both sides.
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    static let definitions: [ChatTool] = [
        ChatTool(function: ChatTool.Function(
            name: "read_file",
            description: """
            Read a UTF-8 text file from the pull request's worktree. Paths are relative to the \
            worktree root — start with `.review-bot-diff.patch` (the diff under review), \
            `.review-bot-thread.md` (the PR discussion), and `.review-bot-merge.md` (how the PR \
            interacts with a base branch that has moved since; absent when it has not). Returns \
            numbered lines.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Path relative to the worktree root."),
                    ]),
                    "offset": .object([
                        "type": .string("integer"),
                        "description": .string("1-based line to start from. Defaults to 1."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum lines to return. Defaults to 600."),
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        )),
        ChatTool(function: ChatTool.Function(
            name: "search",
            description: """
            Search the worktree's text files for a regular expression and return matching \
            `path:line: text` entries. Use it to find callers, definitions, and similar patterns. \
            Dot-prefixed paths are searched too, so the `.review-bot-*` files and configuration \
            like `.github/` are included; only `.git` itself is skipped.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("An ICU regular expression."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional subdirectory or file to limit the search to."
                        ),
                    ]),
                ]),
                "required": .array([.string("pattern")]),
            ])
        )),
        ChatTool(function: ChatTool.Function(
            name: "list_files",
            description: """
            List the files and directories under a path in the worktree. Dot-prefixed entries \
            are listed, so a `.review-bot-*` file missing from the root listing is genuinely \
            not there; only `.git` is hidden.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional directory relative to the worktree root. Defaults to the root."
                        ),
                    ]),
                ]),
                "required": .array([]),
            ])
        )),
    ]

    /// A file's raw text, without the line numbering and per-read limits the `read_file` tool
    /// applies. Used to inline the diff and PR thread in the opening message, which clips them to
    /// its own budget — so this deliberately imposes no size limit of its own beyond what can be
    /// held in memory. Still refuses anything outside the worktree.
    func rawContents(of relativePath: String) -> String? {
        guard let url = resolve(relativePath) else { return nil }
        return try? textContents(of: url).get()
    }

    /// Runs one tool call. Never throws: a failure is returned as text so the model can correct
    /// itself and keep reviewing.
    func execute(name: String, argumentsJSON: String) -> String {
        let arguments = Arguments(json: argumentsJSON)
        switch name {
        case "read_file":
            guard let path = arguments.path else { return "Error: `path` is required." }
            return readFile(path: path, offset: arguments.offset, limit: arguments.limit)
        case "search":
            guard let pattern = arguments.pattern else { return "Error: `pattern` is required." }
            return search(pattern: pattern, path: arguments.path)
        case "list_files":
            return listFiles(path: arguments.path)
        default:
            return "Error: unknown tool `\(name)`."
        }
    }

    // MARK: - Tools

    private func readFile(path: String, offset: Int?, limit: Int?) -> String {
        guard let url = resolve(path) else { return refusal(path) }
        let contents: String
        switch textContents(of: url) {
        case let .success(text): contents = text
        case let .failure(reason): return explain(reason, for: path)
        }

        let lines = contents.components(separatedBy: .newlines)
        let start = max(1, offset ?? 1)
        guard start <= lines.count else {
            return "Error: `\(path)` has \(lines.count) lines; offset \(start) is past the end."
        }
        let count = min(max(1, limit ?? Limits.maxReadLines), Limits.maxReadLines)
        let end = min(lines.count, start + count - 1)

        var rendered = (start...end)
            .map { "\($0)\t\(lines[$0 - 1])" }
            .joined(separator: "\n")
        if end < lines.count {
            rendered += "\n… \(lines.count - end) more lines. Read again with offset \(end + 1)."
        }
        return truncated(rendered)
    }

    private func search(pattern: String, path: String?) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return "Error: `\(pattern)` is not a valid regular expression."
        }
        let scope = path.map { resolve($0) } ?? root
        guard let scope else { return refusal(path ?? "") }

        var results: [String] = []
        var scanned = 0
        for file in files(under: scope) {
            if results.count >= Limits.maxSearchResults || scanned >= Limits.maxSearchedFiles {
                break
            }
            scanned += 1
            guard let contents = try? textContents(of: file).get() else { continue }
            let relative = relativePath(of: file)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                guard results.count < Limits.maxSearchResults else { break }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard expression.firstMatch(in: line, range: range) != nil else { continue }
                results.append("\(relative):\(index + 1): \(String(line.prefix(300)))")
            }
        }

        if results.isEmpty { return "No matches for `\(pattern)`." }
        var rendered = results.joined(separator: "\n")
        if results.count >= Limits.maxSearchResults {
            rendered += "\n… more matches were suppressed. Narrow the pattern or the path."
        }
        return truncated(rendered)
    }

    private func listFiles(path: String?) -> String {
        let target = path.map { resolve($0) } ?? root
        guard let target else { return refusal(path ?? "") }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return "Error: `\(path ?? ".")` is not a readable directory."
        }

        let rendered = entries
            .filter { $0.lastPathComponent != ".git" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Limits.maxListedEntries)
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                return relativePath(of: entry) + (isDirectory ? "/" : "")
            }
            .joined(separator: "\n")
        return rendered.isEmpty ? "(empty directory)" : truncated(rendered)
    }

    // MARK: - Containment

    /// Resolves a model-supplied path against the worktree root, or `nil` when it escapes it.
    func resolve(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("~") else { return nil }

        let candidate = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : root.appendingPathComponent(trimmed)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        guard isContained(resolved) else { return nil }
        guard fileManager.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// Whether a URL lands inside the worktree once symlinks and `..` are resolved away. The
    /// single containment rule, so the walked-file path and the model-named path cannot drift.
    private func isContained(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    private func refusal(_ path: String) -> String {
        "Error: `\(path)` is outside the review worktree or does not exist. "
            + "Use paths relative to the worktree root."
    }

    private func relativePath(of url: URL) -> String {
        // `root` was normalised in `init`, so the candidate has to be normalised the same way
        // before the prefix comparison means anything. A macOS temporary directory is the case
        // that exposes it: the enumerator hands back `/private/var/…` while `root.path` is
        // `/var/…`, the prefix check fails, and every hit in a subdirectory is reported as a bare
        // filename the model then cannot read back or cite as `path:line`.
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.path.count + 1))
    }

    private func files(under url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }

        // Deliberately *not* `.skipsHiddenFiles`. Everything Review Bot writes for the reviewer is
        // dot-prefixed — `.review-bot-diff.patch`, `.review-bot-thread.md`, `.review-bot-merge.md`
        // — as is much of what a pull request changes (`.github/workflows`, lint and CI config).
        // Skipping them made `search` answer "No matches" for text that is demonstrably in the
        // worktree, which reads as evidence of absence. `.git` is pruned by name below instead.
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var collected: [URL] = []
        for case let entry as URL in enumerator {
            if entry.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let isRegular = (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            // `resourceValues` follows symlinks, so a link committed in the pull request would
            // otherwise report as a regular file and have its *target* read — the containment
            // `resolve(_:)` enforces for a named path, enforced again for a walked one.
            if isRegular, isContained(entry) { collected.append(entry) }
            if collected.count >= Limits.maxSearchedFiles { break }
        }
        return collected
    }

    /// Why a file could not be turned into text. The distinction matters to the reader: a model
    /// told "not readable UTF-8" concludes the file is corrupt and stops, while "too large, page
    /// through it" is an instruction it can act on. Reporting all three as the first one is how a
    /// 1.5 MB diff — perfectly valid UTF-8 — got a review that said the pull request could not be
    /// reviewed at all.
    private enum TextRefusal: Error {
        case tooLargeToLoad(bytes: Int)
        case binary
        case notUTF8
    }

    /// The file's full text, or why it cannot be read as text.
    ///
    /// Size is deliberately *not* a reason on its own. `readFile` slices what it returns and
    /// `search` matches line by line, so a large file is served a piece at a time rather than
    /// refused; only a file too big to hold in memory at all is turned away, and it says so.
    private func textContents(of url: URL) -> Result<String, TextRefusal> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Limits.maxLoadableBytes else { return .failure(.tooLargeToLoad(bytes: size)) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.notUTF8) }
        guard !data.prefix(8_000).contains(0) else { return .failure(.binary) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
        return .success(text)
    }

    private func explain(_ refusal: TextRefusal, for path: String) -> String {
        switch refusal {
        case let .tooLargeToLoad(bytes):
            let megabytes = Double(bytes) / 1_000_000
            return "Error: `\(path)` is \(String(format: "%.1f", megabytes)) MB, too large to open. "
                + "Use `search` to find the parts you need."
        case .binary:
            return "Error: `\(path)` is a binary file, not text."
        case .notUTF8:
            return "Error: `\(path)` is not valid UTF-8 text."
        }
    }

    private func truncated(_ value: String) -> String {
        guard value.count > Limits.maxOutputCharacters else { return value }
        return String(value.prefix(Limits.maxOutputCharacters)) + "\n… output truncated."
    }

    /// The union of every tool's parameters. Providers occasionally emit malformed or partial
    /// argument objects, so each field is optional and validated by the tool that needs it.
    private struct Arguments: Decodable {
        var path: String?
        var pattern: String?
        var offset: Int?
        var limit: Int?

        init(json: String) {
            let decoded = try? JSONDecoder().decode(Arguments.self, from: Data(json.utf8))
            self = decoded ?? Arguments()
        }

        init() {}
    }
}
