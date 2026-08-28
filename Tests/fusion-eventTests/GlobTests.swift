import XCTest
@testable import fusion_event

final class GlobTests: XCTestCase {
    func testEmptyPatternMatchesAll() {
        XCTAssertTrue(Glob.match(pattern: nil, path: "/any/path"))
        XCTAssertTrue(Glob.match(pattern: "", path: "/any/path"))
    }

    func testExactMatch() {
        XCTAssertTrue(Glob.match(pattern: "/a/b.swift", path: "/a/b.swift"))
        XCTAssertFalse(Glob.match(pattern: "/a/b.swift", path: "/a/c.swift"))
    }

    func testSingleStarMatchesWithinSegment() {
        XCTAssertTrue(Glob.match(pattern: "/src/*.swift", path: "/src/foo.swift"))
        XCTAssertTrue(Glob.match(pattern: "/src/*.swift", path: "/src/bar.swift"))
        XCTAssertFalse(Glob.match(pattern: "/src/*.swift", path: "/src/sub/foo.swift"))
        XCTAssertFalse(Glob.match(pattern: "/src/*.swift", path: "/src/foo.txt"))
    }

    func testDoubleStarMatchesAcrossDirs() {
        XCTAssertTrue(Glob.match(pattern: "/src/**/*.swift", path: "/src/a/b/c.swift"))
        XCTAssertTrue(Glob.match(pattern: "/src/**/*.swift", path: "/src/foo.swift"))
        XCTAssertFalse(Glob.match(pattern: "/src/**/*.swift", path: "/other/foo.swift"))
    }

    func testQuestionMarkSingleChar() {
        XCTAssertTrue(Glob.match(pattern: "/src/?.swift", path: "/src/a.swift"))
        XCTAssertFalse(Glob.match(pattern: "/src/?.swift", path: "/src/ab.swift"))
        XCTAssertFalse(Glob.match(pattern: "/src/?.swift", path: "/src//.swift"))
    }

    func testPrefixStarInPath() {
        XCTAssertTrue(Glob.match(pattern: "/Users/you/fe_trig/*", path: "/Users/you/fe_trig/hit.txt"))
        XCTAssertFalse(Glob.match(pattern: "/Users/you/fe_trig/*", path: "/Users/you/other/hit.txt"))
    }
}
