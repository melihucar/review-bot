import XCTest
@testable import ReviewBot

final class ProcessRunnerTests: XCTestCase {
    private let home = "/Users/tester"
    private let minimalPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    func testComposePATHPrependsLoginShellPathSoVersionManagerDirsResolve() {
        let shellPath = "\(home)/.nvm/versions/node/v22.23.1/bin:/opt/homebrew/bin:\(minimalPath)"
        let composed = ProcessRunner.composePATH(
            shellPath: shellPath,
            inherited: minimalPath,
            home: home
        )
        let entries = composed.split(separator: ":").map(String.init)

        // The nvm dir from the login shell is now reachable...
        XCTAssertTrue(entries.contains("\(home)/.nvm/versions/node/v22.23.1/bin"))
        // ...and it comes before the plain system dirs that a launchd app starts with.
        let nvmIndex = entries.firstIndex(of: "\(home)/.nvm/versions/node/v22.23.1/bin")
        let usrBinIndex = entries.firstIndex(of: "/usr/bin")
        XCTAssertNotNil(nvmIndex)
        XCTAssertNotNil(usrBinIndex)
        XCTAssertLessThan(nvmIndex!, usrBinIndex!)
    }

    func testComposePATHDeduplicatesPreservingFirstOccurrence() {
        let composed = ProcessRunner.composePATH(
            shellPath: "/opt/homebrew/bin:/usr/bin",
            inherited: minimalPath,
            home: home
        )
        let entries = composed.split(separator: ":").map(String.init)

        XCTAssertEqual(entries.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertEqual(entries.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testComposePATHFallsBackToFixedListWhenNoShellPath() {
        let composed = ProcessRunner.composePATH(
            shellPath: nil,
            inherited: minimalPath,
            home: home
        )
        let entries = composed.split(separator: ":").map(String.init)

        // The original fixed install dirs are still present as a fallback.
        XCTAssertTrue(entries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(entries.contains("/usr/local/bin"))
        XCTAssertTrue(entries.contains("\(home)/.local/bin"))
        XCTAssertTrue(entries.contains("\(home)/.npm-global/bin"))
        // And the inherited system dirs remain reachable.
        XCTAssertTrue(entries.contains("/usr/bin"))
    }

    func testComposePATHIgnoresEmptySegments() {
        let composed = ProcessRunner.composePATH(
            shellPath: "::/opt/homebrew/bin::",
            inherited: minimalPath,
            home: home
        )
        let entries = composed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        XCTAssertFalse(entries.contains(""))
    }
}
