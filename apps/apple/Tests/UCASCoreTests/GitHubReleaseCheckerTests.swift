import XCTest
@testable import UCASCore

final class GitHubReleaseCheckerTests: XCTestCase {
    func testVersionComparisonIsNumeric() throws {
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("1.9.9")), try XCTUnwrap(ReleaseVersion("v1.10.0")))
        XCTAssertEqual(try XCTUnwrap(ReleaseVersion("v2.3.4")).description, "2.3.4")
        XCTAssertEqual(try XCTUnwrap(ReleaseVersion("0.1.0")).description, "0.1.0")
    }

    func testRejectsUnsupportedTags() {
        for value in ["1.2", "v1.2.3-beta", "01.2.3", ""] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
    }

    func testParsesNewerRelease() throws {
        let data = Data(#"{"tag_name":"v1.10.0","html_url":"https://github.com/WXRIW/UCAS-Sign-In/releases/tag/v1.10.0"}"#.utf8)
        let release = try GitHubReleaseChecker.parse(data: data, installed: XCTUnwrap(ReleaseVersion("1.9.9")))
        XCTAssertEqual(release?.version.description, "1.10.0")
        XCTAssertEqual(release?.tag, "v1.10.0")
    }

    func testDoesNotOfferSameRelease() throws {
        let data = Data(#"{"tag_name":"v1.10.0","html_url":"https://github.com/WXRIW/UCAS-Sign-In/releases/tag/v1.10.0"}"#.utf8)
        XCTAssertNil(try GitHubReleaseChecker.parse(data: data, installed: XCTUnwrap(ReleaseVersion("1.10.0"))))
    }

    func testRejectsUnexpectedReleaseURL() throws {
        let data = Data(#"{"tag_name":"v2.0.0","html_url":"https://example.com/download"}"#.utf8)
        XCTAssertThrowsError(try GitHubReleaseChecker.parse(data: data, installed: XCTUnwrap(ReleaseVersion("1.0.0"))))
    }
}
