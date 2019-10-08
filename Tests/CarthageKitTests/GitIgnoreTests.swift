@testable import CarthageKit
import Foundation
import XCTest

class GitIgnoreTests: XCTestCase {
    
    func testGitIgnorePattern(pattern: String, relativePath: String, isDirectory: Bool = false, expectedOutcome: Bool, file: StaticString = #file, line: UInt = #line) {
        testGitIgnorePatterns(patterns: [pattern], relativePath: relativePath, isDirectory: isDirectory, expectedOutcome: expectedOutcome, file: file, line: line)
    }
 
    func testGitIgnorePatterns(patterns: [String], relativePath: String, isDirectory: Bool = false, expectedOutcome: Bool, file: StaticString = #file, line: UInt = #line) {
        
        let gitIgnore = GitIgnore()
        for pattern in patterns {
            gitIgnore.addPattern(pattern)
        }
        
        let outcome = gitIgnore.matches(relativePath: relativePath, isDirectory: isDirectory)
        
        XCTAssertEqual(outcome, expectedOutcome, file: file, line: line)
    }
    
    func testPatterns() {
        
        // Empty strings are not patterns
        testGitIgnorePattern(pattern: "foo", relativePath: "foo/bba/arr", expectedOutcome: false)
        testGitIgnorePattern(pattern: "foo", relativePath: "bba/foo/arr", expectedOutcome: false)
        testGitIgnorePattern(pattern: "foo", relativePath: "bba/arr/foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: "foo", relativePath: "bba/foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: "foo", relativePath: "foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: "foo", relativePath: "foos", expectedOutcome: false)
        
        testGitIgnorePatterns(patterns: ["foo", "!foo"], relativePath: "foo", expectedOutcome: false)
        
        testGitIgnorePattern(pattern: "\\!foo", relativePath: "!foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: "\\!foo!", relativePath: "!foo!", expectedOutcome: true)
        testGitIgnorePattern(pattern: "\\#foo", relativePath: "#foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: "#foo", relativePath: "#foo", expectedOutcome: false)
        testGitIgnorePattern(pattern: "\\#foo#", relativePath: "#foo#", expectedOutcome: true)
        testGitIgnorePattern(pattern: "\\ foo", relativePath: " foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: "\\ foo ", relativePath: " foo ", expectedOutcome: false)
        testGitIgnorePattern(pattern: "\\\\foo", relativePath: "\\foo", expectedOutcome: true)

        testGitIgnorePattern(pattern: "  foo  ", relativePath: "foo", expectedOutcome: false)
        testGitIgnorePattern(pattern: "  foo\\  ", relativePath: "foo", expectedOutcome: false)
        testGitIgnorePattern(pattern: "  foo\\  ", relativePath: "foo ", expectedOutcome: false)

        testGitIgnorePattern(pattern: " foo  ", relativePath: " foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: " foo\\  ", relativePath: " foo", expectedOutcome: false)
        testGitIgnorePattern(pattern: " foo\\  ", relativePath: " foo ", expectedOutcome: true)

        testGitIgnorePattern(pattern: "\\ foo ", relativePath: " foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: "\\ foo \\   ", relativePath: " foo  ", expectedOutcome: true)

        testGitIgnorePattern(pattern: "foo/", relativePath: "bba/arr/foo", isDirectory: true, expectedOutcome: true)
        testGitIgnorePattern(pattern: "foo/", relativePath: "bba/arr/foo", isDirectory: false, expectedOutcome: false)

        testGitIgnorePattern(pattern: "bba/foo/arr/", relativePath: "bba/foo/arr", isDirectory: true, expectedOutcome: true)
        testGitIgnorePattern(pattern: "bba/foo/arr/", relativePath: "bba/foo/arr", isDirectory: false, expectedOutcome: false)

        testGitIgnorePattern(pattern: "/", relativePath: "foo", isDirectory: false, expectedOutcome: false)
        testGitIgnorePattern(pattern: "/", relativePath: "foo", isDirectory: true, expectedOutcome: false)
        testGitIgnorePattern(pattern: "!", relativePath: "foo", isDirectory: false, expectedOutcome: false)

        testGitIgnorePattern(pattern: "!/foo", relativePath: "foo", isDirectory: true, expectedOutcome: false)

        testGitIgnorePattern(pattern: "   ", relativePath: " ", isDirectory: false, expectedOutcome: false)
    }
    
}
