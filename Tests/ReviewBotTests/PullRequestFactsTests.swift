import Foundation
import XCTest
@testable import ReviewBot

final class PullRequestFactsTests: XCTestCase {
    private static let headOid = String(repeating: "a", count: 40)
    private static let baseOid = String(repeating: "b", count: 40)
    private static let differentOid = String(repeating: "c", count: 40)

    /// Builds `PullRequestMetadata` by decoding JSON — it is `Decodable`-only, so this is the only
    /// way a test can construct one. Omits `headRefName`/`isCrossRepository` from the JSON when the
    /// caller passes `nil`, to also exercise decoding a response that predates those keys.
    private func metadata(
        headRefName: String?,
        isCrossRepository: Bool?,
        headRefOid: String = PullRequestFactsTests.headOid,
        baseRefName: String = "main",
        baseRefOid: String = PullRequestFactsTests.baseOid
    ) throws -> PullRequestMetadata {
        var fields: [String: Any] = [
            "title": "Test PR",
            "headRefOid": headRefOid,
            "baseRefName": baseRefName,
            "baseRefOid": baseRefOid,
            "url": "https://github.com/acme/widget/pull/1",
        ]
        if let headRefName {
            fields["headRefName"] = headRefName
        }
        if let isCrossRepository {
            fields["isCrossRepository"] = isCrossRepository
        }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(PullRequestMetadata.self, from: data)
    }

    func testTheStalenessWarningCoversReviewBotsOwnBareClone() throws {
        let pr = try metadata(headRefName: "feature", isCrossRepository: false)

        let rendered = PullRequestFacts(metadata: pr, headBranchTip: Self.headOid).render()

        XCTAssertTrue(rendered.contains("Review Bot's own bare clone, whose local branches were frozen when it was cloned"))
        XCTAssertTrue(rendered.contains("may be days out of date"))
    }

    func testDecodingWithoutTheNewKeysStillSucceeds() throws {
        let json = """
        {"title":"Test PR","headRefOid":"\(Self.headOid)","baseRefName":"main","baseRefOid":"\(Self.baseOid)","url":"https://github.com/acme/widget/pull/1"}
        """
        let decoded = try JSONDecoder().decode(PullRequestMetadata.self, from: Data(json.utf8))

        XCTAssertNil(decoded.headRefName)
        XCTAssertNil(decoded.isCrossRepository)
        XCTAssertEqual(decoded.headRepository, .unknown)
        XCTAssertNil(decoded.fetchableHeadRefName)
    }

    func testSameRepositoryWithMatchingTipNamesBothRefreshedRefs() throws {
        let pr = try metadata(headRefName: "develop", isCrossRepository: false)
        let rendered = PullRequestFacts(metadata: pr, headBranchTip: Self.headOid).render()

        XCTAssertTrue(rendered.contains("## Pull request facts"))
        XCTAssertTrue(rendered.contains("`develop`, in this same repository"))
        XCTAssertTrue(rendered.contains(Self.headOid), "the full OID must appear, never truncated")
        XCTAssertTrue(rendered.contains("the same commit"))
        XCTAssertTrue(rendered.contains("refreshed only `origin/main` and `origin/develop`;"))
    }

    func testSameRepositoryWithDifferingTipFlagsItExplicitly() throws {
        let pr = try metadata(headRefName: "develop", isCrossRepository: false)
        let rendered = PullRequestFacts(metadata: pr, headBranchTip: Self.differentOid).render()

        XCTAssertTrue(rendered.contains(Self.headOid), "the commit under review must still appear in full")
        XCTAssertTrue(rendered.contains(Self.differentOid), "the fetched tip must appear in full")
        XCTAssertTrue(rendered.contains("**not** the commit under review"))
    }

    func testSameRepositoryWithUnreadableTipSaysSo() throws {
        let pr = try metadata(headRefName: "develop", isCrossRepository: false)
        let rendered = PullRequestFacts(metadata: pr, headBranchTip: nil).render()

        XCTAssertTrue(rendered.contains("could not be read back"))
        // The fetch still happened even though the read-back failed, so the refreshed-refs
        // sentence still names both refs.
        XCTAssertTrue(rendered.contains("refreshed only `origin/main` and `origin/develop`;"))
    }

    func testForkNamesOnlyTheBaseAmongRefreshedRefsAndHasNoTipLine() throws {
        let pr = try metadata(headRefName: "feature/outside", isCrossRepository: true)
        let rendered = PullRequestFacts(metadata: pr, headBranchTip: nil).render()

        XCTAssertTrue(rendered.contains("in a fork"))
        XCTAssertTrue(rendered.contains("refreshed only `origin/main`;"))
        XCTAssertFalse(rendered.contains("as fetched from the clone's `origin` remote"), "a fork's tip is never fetched")
    }

    func testUnknownRelationshipDoesNotFetchTheHead() throws {
        let pr = try metadata(headRefName: "develop", isCrossRepository: nil)
        let rendered = PullRequestFacts(metadata: pr, headBranchTip: nil).render()

        XCTAssertTrue(rendered.contains("did not report whether it lives in this repository or a fork"))
        XCTAssertTrue(rendered.contains("refreshed only `origin/main`;"))
    }

    func testNoReportedNameSaysSoAndDoesNotFetch() throws {
        let pr = try metadata(headRefName: nil, isCrossRepository: false)
        let rendered = PullRequestFacts(metadata: pr, headBranchTip: nil).render()

        XCTAssertTrue(rendered.contains("GitHub did not report its name"))
        XCTAssertTrue(rendered.contains("refreshed only `origin/main`;"))
    }

    /// Git allows a backtick in a ref name. The facts must still name the exact branch, so the
    /// code span grows its fence rather than rewriting the name.
    func testBacktickInABranchNameIsShownExactly() throws {
        let pr = try metadata(headRefName: "feat`x", isCrossRepository: false)
        let rendered = PullRequestFacts(metadata: pr, headBranchTip: Self.headOid).render()

        XCTAssertTrue(rendered.contains("from: `` feat`x ``, in this same repository"))
        XCTAssertTrue(rendered.contains("`` origin/feat`x ``"))
        XCTAssertFalse(rendered.contains("feat'x"))
    }
}
