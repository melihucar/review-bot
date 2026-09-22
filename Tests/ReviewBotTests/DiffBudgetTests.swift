import Foundation
import XCTest
@testable import ReviewBot

final class DiffBudgetTests: XCTestCase {
    private func section(path: String, addedLines: Int, removedLines: Int, padding: Int = 0) -> String {
        var lines = [
            "diff --git a/\(path) b/\(path)",
            "index 1111111..2222222 100644",
            "--- a/\(path)",
            "+++ b/\(path)",
            "@@ -1,\(removedLines) +1,\(addedLines) @@",
        ]
        for index in 0..<addedLines {
            lines.append("+line \(index)" + String(repeating: "x", count: padding))
        }
        for index in 0..<removedLines {
            lines.append("-old line \(index)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Under the limit

    /// The path ~every real pull request takes, and the most important assertion in this file:
    /// nothing here may reformat, re-line-wrap, or otherwise touch a diff that already fits.
    func testUnderLimitInputIsReturnedByteIdentical() {
        let diff = [
            section(path: "a.swift", addedLines: 2, removedLines: 1),
            section(path: "b.swift", addedLines: 3, removedLines: 0),
        ].joined(separator: "\n")

        let outcome = DiffBudget.fit(diff, limit: 1_000_000)

        XCTAssertEqual(outcome.patch, diff, "a diff under the limit must not be touched at all")
        XCTAssertEqual(outcome.totalFiles, 2)
        XCTAssertEqual(outcome.includedFiles, 2)
        XCTAssertEqual(outcome.omittedFiles, 0)
        XCTAssertFalse(outcome.includesCutFile)
        XCTAssertFalse(outcome.isTruncated)
    }

    func testEmptyDiffIsUnaffected() {
        let outcome = DiffBudget.fit("", limit: 1_000)

        XCTAssertEqual(outcome.patch, "")
        XCTAssertEqual(outcome.totalFiles, 0)
        XCTAssertEqual(outcome.includedFiles, 0)
        XCTAssertFalse(outcome.includesCutFile)
        XCTAssertFalse(outcome.isTruncated)
    }

    // MARK: - Over the limit, whole-section truncation

    func testOverLimitInputKeepsOnlyWholeSections() {
        let first = section(path: "one.swift", addedLines: 4, removedLines: 0)
        let second = section(path: "two.swift", addedLines: 4, removedLines: 0)
        let third = section(path: "three.swift", addedLines: 4, removedLines: 0)
        let diff = [first, second, third].joined(separator: "\n")

        // A limit that fits the first section exactly, but leaves no room for the second: the
        // greedy accumulation must stop rather than skip ahead to see if something smaller fits.
        let limit = first.utf8.count

        let outcome = DiffBudget.fit(diff, limit: limit)

        XCTAssertEqual(outcome.totalFiles, 3)
        XCTAssertEqual(outcome.includedFiles, 1)
        XCTAssertEqual(outcome.omittedFiles, 2)
        XCTAssertTrue(outcome.isTruncated)
        XCTAssertTrue(outcome.patch.contains(first), "the section that fit must appear verbatim")
        // The omitted sections' hunks must not appear anywhere in the patch — only their names
        // and counts, in the closing block. No section may be half-present.
        XCTAssertFalse(outcome.patch.contains("diff --git a/two.swift"))
        XCTAssertFalse(outcome.patch.contains("diff --git a/three.swift"))
    }

    func testEveryFileAppearsInTheFullChangeSummary() {
        let diff = [
            section(path: "included.swift", addedLines: 2, removedLines: 0),
            section(path: "omitted-one.swift", addedLines: 2, removedLines: 0),
            section(path: "omitted-two.swift", addedLines: 2, removedLines: 0),
        ].joined(separator: "\n")
        let limit = section(path: "included.swift", addedLines: 2, removedLines: 0).utf8.count

        let outcome = DiffBudget.fit(diff, limit: limit)

        XCTAssertTrue(outcome.patch.contains("FULL CHANGE SUMMARY (3 files)"))
        for path in ["included.swift", "omitted-one.swift", "omitted-two.swift"] {
            XCTAssertTrue(
                outcome.patch.contains(path),
                "\(path) must be named in the summary even when its hunks are not shown"
            )
        }
    }

    func testOmittedFilesAreNamedInTheClosingBlockWithCorrectCounts() {
        let kept = section(path: "kept.swift", addedLines: 2, removedLines: 0)
        let dropped = section(path: "dropped.swift", addedLines: 5, removedLines: 3)
        let diff = [kept, dropped].joined(separator: "\n")

        let outcome = DiffBudget.fit(diff, limit: kept.utf8.count)

        XCTAssertEqual(outcome.totalFiles, 2)
        XCTAssertEqual(outcome.includedFiles, 1)
        XCTAssertEqual(outcome.omittedFiles, 1)
        XCTAssertTrue(outcome.patch.contains("TRUNCATED — 1 file not shown above"))
        XCTAssertTrue(outcome.patch.contains("`dropped.swift`: +5 -3"))
        XCTAssertTrue(
            outcome.patch.contains("checked out in the working directory"),
            "the closing block must tell the reviewer the omitted files are still readable"
        )
        XCTAssertTrue(
            outcome.patch.contains("diff for it was truncated"),
            "the closing block must require findings in omitted files to disclose the truncation"
        )
    }

    func testCountsReflectWhatWasActuallyIncluded() {
        let sections = (1...5).map { section(path: "file\($0).swift", addedLines: 3, removedLines: 0) }
        let diff = sections.joined(separator: "\n")
        // Room for exactly the first two sections.
        let limit = sections[0].utf8.count + sections[1].utf8.count

        let outcome = DiffBudget.fit(diff, limit: limit)

        XCTAssertEqual(outcome.totalFiles, 5)
        XCTAssertEqual(outcome.includedFiles, 2)
        XCTAssertEqual(outcome.omittedFiles, 3)
        XCTAssertTrue(outcome.isTruncated)
        // Nothing was cut mid-file here — every included section is whole — so the count the
        // review quotes matches the count included.
        XCTAssertFalse(outcome.includesCutFile)
        XCTAssertEqual(outcome.completeFiles, 2)
    }

    // MARK: - The pathological case: the very first file alone busts the budget

    /// Regression test for a real bug: with `isTruncated` defined only as `omittedFiles > 0`,
    /// this exact case — one file whose section alone exceeds the limit — reported "nothing was
    /// truncated" while silently cutting the file's hunks part-way through, so a posted review
    /// would have claimed full coverage of a file it only partially saw.
    func testSingleOversizedFirstSectionIsCutRatherThanOmittedEntirely() {
        // One enormous first file and nothing else: the whole budget is spent showing as much of
        // it as fits, and there is no second file to be omitted.
        let huge = section(path: "huge-generated.swift", addedLines: 500, removedLines: 0, padding: 200)
        let limit = 500 // Far smaller than `huge` alone, which is what makes this pathological.

        let outcome = DiffBudget.fit(huge, limit: limit)

        XCTAssertEqual(outcome.totalFiles, 1)
        XCTAssertEqual(outcome.includedFiles, 1)
        XCTAssertEqual(outcome.omittedFiles, 0)
        XCTAssertTrue(outcome.includesCutFile, "the single file's hunks were cut part-way through")
        // The count the posted review quotes. It must not be `includedFiles` here: the file is
        // present but only partly shown, so "complete hunks for 1 of 1 files" would describe a
        // partial review as a total one.
        XCTAssertEqual(outcome.completeFiles, 0)
        XCTAssertTrue(
            outcome.isTruncated,
            "a cut file must count as truncation even though no file was omitted entirely"
        )
        XCTAssertTrue(outcome.patch.contains("huge-generated.swift"))
        XCTAssertTrue(
            outcome.patch.contains("cut this file's diff at the \(limit)-byte size limit"),
            "a patch with zero hunks is useless, so the oversized file must still show something"
        )
    }

    /// The same pathological cut, but with a normal file queued up behind the oversized one —
    /// proving the second file is dropped (not shown, not touched) rather than getting a
    /// partial look-in once the first file's budget is spent.
    func testSingleOversizedFirstSectionLeavesNoRoomForFilesBehindIt() {
        let huge = section(path: "huge-generated.swift", addedLines: 500, removedLines: 0, padding: 200)
        let normal = section(path: "normal.swift", addedLines: 2, removedLines: 0)
        let diff = [huge, normal].joined(separator: "\n")
        let limit = 500

        let outcome = DiffBudget.fit(diff, limit: limit)

        XCTAssertEqual(outcome.totalFiles, 2)
        XCTAssertEqual(outcome.includedFiles, 1)
        XCTAssertEqual(outcome.omittedFiles, 1)
        XCTAssertTrue(outcome.includesCutFile)
        XCTAssertTrue(outcome.isTruncated)
        XCTAssertTrue(outcome.patch.contains("`normal.swift`"), "the second file must still be named in the summary/closing block")
        XCTAssertFalse(
            outcome.patch.contains("diff --git a/normal.swift"),
            "the second file's own hunks must never appear — the whole budget went to the first file"
        )
    }

    // MARK: - Path parsing

    func testPathParsingHandlesAnOrdinaryChange() {
        let diff = section(path: "src/Widget.swift", addedLines: 2, removedLines: 1)
            + "\n" + section(path: "second.swift", addedLines: 1, removedLines: 0)

        // Force truncation so the summary (where parsed paths surface) gets built.
        let outcome = DiffBudget.fit(diff, limit: section(path: "src/Widget.swift", addedLines: 2, removedLines: 1).utf8.count)

        XCTAssertTrue(outcome.patch.contains("`src/Widget.swift`"))
    }

    func testPathParsingHandlesARenamedFile() {
        let header = "diff --git a/old/Name.swift b/new/Renamed.swift"
        let rename = [
            header,
            "similarity index 92%",
            "rename from old/Name.swift",
            "rename to new/Renamed.swift",
            "index 1111111..2222222 100644",
            "--- a/old/Name.swift",
            "+++ b/new/Renamed.swift",
            "@@ -1,1 +1,1 @@",
            "-old",
            "+new",
        ].joined(separator: "\n")

        // Force truncation so the summary (where parsed paths surface) gets built.
        let outcome = DiffBudget.fit(
            rename + "\n" + section(path: "second.swift", addedLines: 1, removedLines: 0),
            limit: rename.utf8.count
        )

        XCTAssertTrue(
            outcome.patch.contains("`new/Renamed.swift`"),
            "the path must be taken from after the last ' b/', i.e. the new name"
        )
        XCTAssertFalse(
            outcome.patch.contains("`old/Name.swift`"),
            "the old name from the 'a/' side must not be reported as the file's path"
        )
    }

    func testPathParsingFallsBackToTheWholeHeaderWhenThereIsNoBMarker() {
        // A header with no recognisable " b/" marker at all — parsing must not crash, and must
        // fall back to something rather than produce an empty path.
        let odd = "diff --git weirdheader\nindex 1..2 100644\n@@ -1 +1 @@\n+x"
        let diff = odd + "\n" + section(path: "second.swift", addedLines: 1, removedLines: 0)

        let outcome = DiffBudget.fit(diff, limit: odd.utf8.count)

        XCTAssertTrue(outcome.patch.contains("weirdheader"))
    }

    // MARK: - Added/removed counting

    func testAddedAndRemovedCountsIgnoreTheHunkHeaders() {
        // `+++`/`---` both share a prefix with a bare "+"/"-" content line, so the summary line
        // must not count the file headers themselves as an added or removed line.
        let diff = section(path: "counts.swift", addedLines: 3, removedLines: 2)
        let second = section(path: "second.swift", addedLines: 1, removedLines: 0)

        let outcome = DiffBudget.fit(diff + "\n" + second, limit: diff.utf8.count)

        XCTAssertTrue(
            outcome.patch.contains("`counts.swift`: +3 -2"),
            "the +++/--- headers must not be counted as content changes"
        )
    }

    // MARK: - No file boundary at all

    func testOverLimitBlobWithNoFileHeaderIsReturnedUntouched() {
        let blob = String(repeating: "not a diff at all, just a giant blob of text\n", count: 200)
        XCTAssertGreaterThan(blob.utf8.count, 1_000, "the fixture must actually exceed the limit below")

        let outcome = DiffBudget.fit(blob, limit: 1_000)

        XCTAssertEqual(outcome.patch, blob, "with nothing to split on, the text must come back untouched")
        XCTAssertEqual(outcome.totalFiles, 0)
        XCTAssertEqual(outcome.includedFiles, 0)
        XCTAssertFalse(outcome.includesCutFile)
        XCTAssertFalse(outcome.isTruncated, "there is no file to have been cut or omitted")
    }

    // MARK: - Non-ASCII near the cut boundary

    /// The cut must never split a multi-byte UTF-8 character in half — that would produce a
    /// string that fails to decode. Pads the oversized file's content with multi-byte characters
    /// straddling exactly where the byte-limit cut lands.
    func testCutNearNonASCIIContentStillDecodes() {
        // Each "é" is 2 UTF-8 bytes, so a limit landing mid-run is guaranteed to fall inside one
        // of them somewhere across this many repetitions.
        let nonASCIILine = "+" + String(repeating: "é", count: 50)
        var lines = [
            "diff --git a/emoji.swift b/emoji.swift",
            "index 1111111..2222222 100644",
            "--- a/emoji.swift",
            "+++ b/emoji.swift",
            "@@ -1,0 +1,50 @@",
        ]
        for _ in 0..<50 { lines.append(nonASCIILine) }
        let huge = lines.joined(separator: "\n")

        // Try every limit across the oversized section's byte range: whichever one lands mid
        // character, the result must still be valid, decodable UTF-8 (which `String` guarantees
        // by construction) — the point under test is that no runtime trap/crash occurs and the
        // returned patch is non-empty.
        for limit in stride(from: 20, to: min(huge.utf8.count, 200), by: 1) {
            let outcome = DiffBudget.fit(huge, limit: limit)
            XCTAssertTrue(outcome.includesCutFile)
            XCTAssertFalse(outcome.patch.isEmpty, "limit \(limit) must still produce output")
        }
    }
}
