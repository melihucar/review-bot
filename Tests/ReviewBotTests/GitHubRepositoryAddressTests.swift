import XCTest
@testable import ReviewBot

final class GitHubRepositoryAddressTests: XCTestCase {
    func testHTTPSShapesParseToTheSameRepository() throws {
        let inputs = [
            "https://github.com/acme/widget",
            "https://github.com/acme/widget.git",
            "https://github.com/acme/widget/",
            "https://github.com/acme/widget.git/",
            "http://github.com/acme/widget",
            "HTTPS://GitHub.com/acme/widget",
            "https://www.github.com/acme/widget",
            "https://github.com/acme/widget?tab=readme#top",
            "github.com/acme/widget",
            "acme/widget",
            "  https://github.com/acme/widget\n",
        ]
        for input in inputs {
            let address = try GitHubRepositoryAddress.parse(input)
            XCTAssertEqual(address.slug, "acme/widget", input)
            XCTAssertEqual(address.transport, .https, input)
        }
    }

    func testSSHShapesParseToTheSameRepository() throws {
        let inputs = [
            "git@github.com:acme/widget.git",
            "git@github.com:acme/widget",
            "github.com:acme/widget.git",
            "ssh://git@github.com/acme/widget.git",
            "ssh://git@github.com:22/acme/widget.git",
        ]
        for input in inputs {
            let address = try GitHubRepositoryAddress.parse(input)
            XCTAssertEqual(address.slug, "acme/widget", input)
            XCTAssertEqual(address.transport, .ssh, input)
        }
    }

    func testCredentialsInAnAddressNeverReachTheCloneURL() throws {
        let address = try GitHubRepositoryAddress.parse("https://user:secret@github.com/acme/widget.git")
        XCTAssertEqual(address.cloneURL, "https://github.com/acme/widget.git")
    }

    func testCloneURLIsRebuiltForBothTransports() throws {
        XCTAssertEqual(
            try GitHubRepositoryAddress.parse("acme/widget").cloneURL,
            "https://github.com/acme/widget.git"
        )
        XCTAssertEqual(
            try GitHubRepositoryAddress.parse("ssh://git@github.com/acme/widget").cloneURL,
            "git@github.com:acme/widget.git"
        )
        XCTAssertEqual(try GitHubRepositoryAddress.parse("a-b/c.d_e").slug, "a-b/c.d_e")
    }

    func testOtherHostsAreRefusedWithTheirName() {
        let inputs = [
            "git@gitlab.com:acme/widget.git": "gitlab.com",
            "https://gitlab.com/acme/widget": "gitlab.com",
            "https://github.example.com/acme/widget": "github.example.com",
            "https://example.com/github.com/acme/widget": "example.com",
            "ssh://git@ssh.github.com:443/acme/widget.git": "ssh.github.com",
        ]
        for (input, host) in inputs {
            XCTAssertThrowsError(try GitHubRepositoryAddress.parse(input), input) { error in
                XCTAssertEqual(error as? RepositoryAddressError, .unsupportedHost(host), input)
            }
        }
    }

    func testAddressesThatDoNotNameARepositoryAreRefused() {
        for input in [
            "https://github.com/acme",
            "https://github.com/acme/widget/pull/12",
            "https://github.com/",
            "github.com/acme",
            "https://github.com/acme/..",
            "acme/wid$get",
        ] {
            XCTAssertThrowsError(try GitHubRepositoryAddress.parse(input), input) { error in
                XCTAssertEqual(error as? RepositoryAddressError, .notARepository, input)
            }
        }
    }

    func testUnrecognizedShapesAreRefused() {
        for input in [
            "widget",
            "git://github.com/acme/widget.git",
            "file:///tmp/x",
            "ext::sh -c x",
            "acme/widget extra",
        ] {
            XCTAssertThrowsError(try GitHubRepositoryAddress.parse(input), input) { error in
                XCTAssertEqual(error as? RepositoryAddressError, .unrecognized, input)
            }
        }
    }

    func testEmptyInputIsRefused() {
        for input in ["", "   "] {
            XCTAssertThrowsError(try GitHubRepositoryAddress.parse(input)) { error in
                XCTAssertEqual(error as? RepositoryAddressError, .empty)
            }
        }
    }

    func testEveryErrorExplainsItself() {
        let errors: [RepositoryAddressError] = [.empty, .unrecognized, .unsupportedHost("gitlab.com"), .notARepository]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
        XCTAssertTrue(RepositoryAddressError.unsupportedHost("gitlab.com").errorDescription?.contains("gitlab.com") == true)
    }

    func testSlugInitializerRejectsAnythingButOwnerAndName() {
        for slug in ["../x", "a/b/c", "a/", "/b", "a/..", "a", ""] {
            XCTAssertNil(GitHubRepositoryAddress(slug: slug, transport: .https), slug)
        }
        XCTAssertNotNil(GitHubRepositoryAddress(slug: "acme/widget", transport: .ssh))
    }
}
