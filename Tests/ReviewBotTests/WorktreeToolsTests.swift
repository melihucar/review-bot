import Foundation
import XCTest
@testable import ReviewBot

final class WorktreeToolsTests: XCTestCase {
    private var root: URL!
    private var tools: WorktreeTools!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotWorktreeTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tools = WorktreeTools(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func testReadFileReturnsNumberedLines() throws {
        try write("alpha\nbeta\ngamma\n", to: "Sources/Widget.swift")

        let output = tools.execute(
            name: "read_file",
            argumentsJSON: #"{"path": "Sources/Widget.swift"}"#
        )

        XCTAssertTrue(output.contains("1\talpha"))
        XCTAssertTrue(output.contains("3\tgamma"))
    }

    func testReadFileHonoursOffsetAndLimit() throws {
        try write((1...20).map { "line \($0)" }.joined(separator: "\n"), to: "notes.txt")

        let output = tools.execute(
            name: "read_file",
            argumentsJSON: #"{"path": "notes.txt", "offset": 5, "limit": 2}"#
        )

        XCTAssertTrue(output.contains("5\tline 5"))
        XCTAssertTrue(output.contains("6\tline 6"))
        XCTAssertFalse(output.contains("7\tline 7"))
        XCTAssertTrue(output.contains("more lines"))
    }

    func testPathsOutsideTheWorktreeAreRefused() throws {
        // A real file that exists, but outside the worktree.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outside) }

        for path in ["../\(outside.lastPathComponent)", outside.path, "/etc/hosts", "~/.zshrc"] {
            let output = tools.execute(
                name: "read_file",
                argumentsJSON: #"{"path": "\#(path)"}"#
            )
            XCTAssertTrue(
                output.hasPrefix("Error:"),
                "\(path) should be refused, got: \(output.prefix(80))"
            )
            XCTAssertFalse(output.contains("secret"))
        }
    }

    func testResolveAcceptsPathsInsideAndRejectsEscapes() throws {
        try write("value", to: "inside.txt")

        XCTAssertNotNil(tools.resolve("inside.txt"))
        XCTAssertNil(tools.resolve("../"))
        XCTAssertNil(tools.resolve("missing.txt"))
        XCTAssertNil(tools.resolve(""))
    }

    func testSearchFindsMatchesAndReportsRelativePaths() throws {
        try write("func alpha() {}\nfunc beta() {}\n", to: "Sources/Widget.swift")
        try write("nothing here\n", to: "Sources/Other.swift")

        let output = tools.execute(
            name: "search",
            argumentsJSON: #"{"pattern": "func beta"}"#
        )

        XCTAssertTrue(output.contains("Sources/Widget.swift:2:"))
        XCTAssertFalse(output.contains("Other.swift"))
    }

    /// Everything Review Bot writes for the reviewer is dot-prefixed, and so is much of what a
    /// pull request changes (`.github/workflows`, lint and CI config). Skipping hidden entries made
    /// `search` answer "No matches" for text that is demonstrably in the worktree — which a
    /// reviewer reads as evidence of absence, not as a tool limitation.
    func testSearchCoversDotPrefixedFilesIncludingTheMergePreview() throws {
        try write("# Merge preview\n\nChanged on both sides: `Widget.swift`\n", to: ".review-bot-merge.md")
        try write("name: ci\n", to: ".github/workflows/ci.yml")

        let preview = tools.execute(
            name: "search",
            argumentsJSON: #"{"pattern": "Changed on both sides"}"#
        )
        XCTAssertTrue(preview.contains(".review-bot-merge.md:3:"), "got: \(preview)")

        // Asserted on the file name rather than the full relative path on purpose: what this test
        // owns is that the walk descends into a hidden *directory* at all.
        // `testSearchFindsMatchesAndReportsRelativePaths` is the one that owns the shape of the
        // path, so a regression in either is reported by exactly one test.
        let workflow = tools.execute(name: "search", argumentsJSON: #"{"pattern": "name: ci"}"#)
        XCTAssertTrue(workflow.contains("ci.yml:1:"), "got: \(workflow)")
    }

    /// The scope gate's one exception rests on `.review-bot-merge.md`, and the reviewer is told to
    /// read it by name, so a dot-prefixed path has to resolve like any other.
    func testTheMergePreviewIsReadableByPathAndAsRawText() throws {
        let contents = "# Merge preview\n\n`develop` has moved 2 commits ahead.\n"
        try write(contents, to: ".review-bot-merge.md")

        let numbered = tools.execute(
            name: "read_file",
            argumentsJSON: #"{"path": ".review-bot-merge.md"}"#
        )
        XCTAssertTrue(numbered.contains("1\t# Merge preview"))
        // `rawContents` is the un-numbered path the opening message inlines it through.
        XCTAssertEqual(tools.rawContents(of: ".review-bot-merge.md"), contents)
        XCTAssertNil(tools.rawContents(of: ".review-bot-merge.md/../../escape"))
    }

    /// A symlink committed in a pull request points wherever its author chose. `resolve(_:)`
    /// refuses one the model names; the walked path has to refuse it too, or `search` reads the
    /// link's *target* and reports contents from outside the worktree as if they were in it.
    func testASymlinkOutOfTheWorktreeIsNeitherReadNorSearched() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("tokenvalue-should-never-appear\n".utf8).write(to: outside, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.txt"),
            withDestinationURL: outside
        )

        let searched = tools.execute(
            name: "search",
            argumentsJSON: #"{"pattern": "tokenvalue-should-never-appear"}"#
        )
        XCTAssertTrue(searched.contains("No matches"), "got: \(searched)")

        let read = tools.execute(name: "read_file", argumentsJSON: #"{"path": "linked.txt"}"#)
        XCTAssertTrue(read.hasPrefix("Error:"))
        XCTAssertFalse(read.contains("tokenvalue-should-never-appear"))
        XCTAssertNil(tools.resolve("linked.txt"))
    }

    func testEveryDeclaredToolIsOneExecuteKnows() {
        // A tool offered to the model but not implemented answers "unknown tool" mid-review,
        // which the model reads as the file not existing.
        let names = WorktreeTools.definitions.map(\.function.name)
        XCTAssertEqual(names, ["read_file", "search", "list_files"])
        for name in names {
            XCTAssertFalse(
                tools.execute(name: name, argumentsJSON: "{}").contains("unknown tool"),
                "\(name) is declared but not handled"
            )
        }
    }

    func testSearchReportsNoMatchesAndInvalidPatterns() throws {
        try write("alpha\n", to: "a.txt")

        XCTAssertTrue(
            tools.execute(name: "search", argumentsJSON: #"{"pattern": "zzz"}"#)
                .contains("No matches")
        )
        XCTAssertTrue(
            tools.execute(name: "search", argumentsJSON: #"{"pattern": "["}"#)
                .hasPrefix("Error:")
        )
    }

    func testListFilesSkipsGitDirectory() throws {
        try write("alpha\n", to: "README.md")
        try write("ref\n", to: ".git/HEAD")

        let output = tools.execute(name: "list_files", argumentsJSON: "{}")

        XCTAssertTrue(output.contains("README.md"))
        XCTAssertFalse(output.contains(".git"))
    }

    func testUnknownToolAndMalformedArgumentsFailSoftly() {
        XCTAssertTrue(
            tools.execute(name: "delete_everything", argumentsJSON: "{}").hasPrefix("Error:")
        )
        XCTAssertTrue(
            tools.execute(name: "read_file", argumentsJSON: "not json").hasPrefix("Error:")
        )
    }

    // MARK: - Large files

    func testAFileLargerThanTheOldCapIsStillReadableAPageAtATime() throws {
        // The regression that made this necessary: a 1.5 MB diff — valid UTF-8 throughout — was
        // refused outright by a 1 MB file cap, and the refusal said "not a readable UTF-8 text
        // file". The reviewer believed it, reported the pull request could not be reviewed, and
        // the panel approved anyway. Size must bound what a read *returns*, never whether the
        // file can be opened.
        let big = (1...40_000).map { "line \($0) of a very large diff" }.joined(separator: "\n")
        XCTAssertGreaterThan(big.utf8.count, 1_000_000, "the fixture has to exceed the old cap")
        try write(big, to: "huge.patch")

        let head = tools.execute(name: "read_file", argumentsJSON: #"{"path":"huge.patch"}"#)
        XCTAssertTrue(head.contains("1\tline 1 of a very large diff"), head)
        XCTAssertFalse(head.contains("Error:"), head)
        XCTAssertTrue(
            head.contains("Read again with offset"),
            "a paged read has to say how to continue, or the reader stops at the first page"
        )

        let later = tools.execute(
            name: "read_file",
            argumentsJSON: #"{"path":"huge.patch","offset":39990,"limit":3}"#
        )
        XCTAssertTrue(later.contains("39990\tline 39990 of a very large diff"), later)

        // `search` used to skip the same files it could not read whole, so a large diff answered
        // "No matches" for text plainly inside it — evidence of absence, manufactured.
        let found = tools.execute(
            name: "search",
            argumentsJSON: #"{"pattern":"line 39999 of"}"#
        )
        XCTAssertTrue(found.contains("huge.patch:39999:"), found)

        XCTAssertNotNil(
            tools.rawContents(of: "huge.patch"),
            "inlining the diff must not be blocked by size either; the caller clips it"
        )
    }

    func testEachReasonAFileCannotBeReadSaysWhichOneItIs() throws {
        try Data([0x00, 0x01, 0x02]).write(to: root.appendingPathComponent("blob.bin"))
        try Data([0xFF, 0xFE, 0xFD]).write(to: root.appendingPathComponent("bad.txt"))

        let binary = tools.execute(name: "read_file", argumentsJSON: #"{"path":"blob.bin"}"#)
        let invalid = tools.execute(name: "read_file", argumentsJSON: #"{"path":"bad.txt"}"#)

        // Three distinct causes used to share one message, and the message named the cause that
        // was usually wrong. A reader told "binary" stops; told "too large" it pages.
        XCTAssertTrue(binary.contains("binary"), binary)
        XCTAssertFalse(binary.contains("UTF-8"), "a binary file is not a UTF-8 problem: \(binary)")
        XCTAssertTrue(invalid.contains("not valid UTF-8"), invalid)
    }
}
