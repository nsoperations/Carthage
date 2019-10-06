@testable import CarthageKit
import Foundation
import XCTest

class GitIgnoreTests: XCTestCase {
    
    func testGitIgnorePattern(pattern: String, relativePath: String, expectedOutcome: Bool, file: StaticString = #file, line: UInt = #line) {
        testGitIgnorePatterns(patterns: [pattern], relativePath: relativePath, expectedOutcome: expectedOutcome, file: file, line: line)
    }
 
    func testGitIgnorePatterns(patterns: [String], relativePath: String, expectedOutcome: Bool, file: StaticString = #file, line: UInt = #line) {
        
        var gitIgnore = GitIgnore()
        for pattern in patterns {
            gitIgnore.addPattern(pattern)
        }
        
        let outcome = gitIgnore.matches(relativePath: relativePath)
        
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
        testGitIgnorePattern(pattern: "\\#foo#", relativePath: "#foo#", expectedOutcome: true)
        testGitIgnorePattern(pattern: "\\ foo", relativePath: " foo", expectedOutcome: true)
        testGitIgnorePattern(pattern: "\\ foo ", relativePath: " foo ", expectedOutcome: true)
        testGitIgnorePattern(pattern: "\\\\foo", relativePath: "\\foo", expectedOutcome: true)
        
        
        
    }
    
}
