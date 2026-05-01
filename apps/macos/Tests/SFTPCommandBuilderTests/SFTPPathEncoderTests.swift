import XCTest
@testable import SFTPCommandBuilder

final class SFTPPathEncoderTests: XCTestCase {
    func testSimplePath() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode("/etc/hosts"), #""/etc/hosts""#)
    }
    func testSpaces() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode("/path/with space/file"),
                       #""/path/with space/file""#)
    }
    func testInnerQuoteEscaped() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode(#"/path/"quoted""#),
                       #""/path/\"quoted\"""#)
    }
    func testBackslashEscaped() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode(#"/path\with\back"#),
                       #""/path\\with\\back""#)
    }
    func testLeadingDashRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encode("-rf")) { err in
            XCTAssertEqual(err as? SFTPPathEncodingError, .leadingDashUnnormalized)
        }
    }
    func testNormalizedLeadingDashAccepted() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode("./-rf"), #""./-rf""#)
    }
    func testNewlineRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encode("file\nname")) { err in
            guard case .containsControlChar(let c) = err as! SFTPPathEncodingError else {
                return XCTFail()
            }
            XCTAssertEqual(c, "\n")
        }
    }
    func testGlobRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encode("*.txt")) { err in
            guard case .containsGlob(let c) = err as! SFTPPathEncodingError else {
                return XCTFail()
            }
            XCTAssertEqual(c, "*")
        }
        XCTAssertThrowsError(try SFTPPathEncoder.encode("[abc].txt"))
    }
    func testEmptyRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encode("")) { err in
            XCTAssertEqual(err as? SFTPPathEncodingError, .empty)
        }
    }
    func testPathTooLongRejected() {
        let long = "/" + String(repeating: "x", count: 1023)
        XCTAssertThrowsError(try SFTPPathEncoder.encode(long)) { err in
            guard case .pathTooLong(let bytes) = err as! SFTPPathEncodingError else {
                return XCTFail()
            }
            XCTAssertGreaterThan(bytes, 1023)
        }
    }
    func testTrailingSlashAccepted() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode("/empty/"), #""/empty/""#)
    }

    // MARK: - encodeRemote (tilde stripping — sftp default cwd is home)

    func testRemoteBareTildeBecomesDot() throws {
        // sftp batch mode does not reliably expand `~`; rely on the fact that
        // its initial cwd is the user's home directory.
        XCTAssertEqual(try SFTPPathEncoder.encodeRemote("~"), #"".""#)
    }

    func testRemoteTildeSlashBecomesDot() throws {
        XCTAssertEqual(try SFTPPathEncoder.encodeRemote("~/"), #"".""#)
    }

    func testRemoteTildePathBecomesRelative() throws {
        XCTAssertEqual(try SFTPPathEncoder.encodeRemote("~/Documents"),
                       #""Documents""#)
        XCTAssertEqual(try SFTPPathEncoder.encodeRemote("~/with space"),
                       #""with space""#)
    }

    func testRemoteAbsolutePathFallsThroughToEncode() throws {
        XCTAssertEqual(try SFTPPathEncoder.encodeRemote("/etc"), #""/etc""#)
    }

    func testRemoteEmptyRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encodeRemote(""))
    }
}
