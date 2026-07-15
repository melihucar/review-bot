import XCTest
@testable import ReviewBot

final class GitHubRemoteParserTests: XCTestCase {
    func testParsesSSHRemote() {
        XCTAssertEqual(
            GitHubRemoteParser.slug(from: "git@github.com:acme/widgets.git"),
            "acme/widgets"
        )
    }

    func testParsesHTTPSRemote() {
        XCTAssertEqual(
            GitHubRemoteParser.slug(from: "https://github.com/acme/widgets.git"),
            "acme/widgets"
        )
    }

    func testParsesSSHURLRemote() {
        XCTAssertEqual(
            GitHubRemoteParser.slug(from: "ssh://git@github.com/acme/widgets.git"),
            "acme/widgets"
        )
    }

    func testRejectsNonGitHubAndMalformedRemotes() {
        XCTAssertNil(GitHubRemoteParser.slug(from: "git@gitlab.com:acme/widgets.git"))
        XCTAssertNil(GitHubRemoteParser.slug(from: "https://github.com/acme"))
    }
}
