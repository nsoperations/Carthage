import Foundation
import Nimble
import XCTest

@testable import CarthageKit

class GitURLTests: XCTestCase {
	func testShouldParseNormalUrl() {
		let expected = "github.com/antitypical/Result"
		expect(GitURL("https://github.com/antitypical/Result.git").normalizedURLString) == expected
		expect(GitURL("https://user:password@github.com:443/antitypical/Result").normalizedURLString) == expected
	}
	
	func testShouldParseLocalAbsolutePath() {
		let expected = "/path/to/git/repo"
		expect(GitURL("/path/to/git/repo.git").normalizedURLString) == expected
		expect(GitURL("/path/to/git/repo").normalizedURLString) == expected
	}
	
	func testShouldParseLocalRelativePath() {
		do {
			let expected = "path/to/git/repo"
			expect(GitURL("path/to/git/repo.git").normalizedURLString) == expected
			expect(GitURL("path/to/git/repo").normalizedURLString) == expected
		}
		
		do {
			let expected = "./path/to/git/repo"
			expect(GitURL("./path/to/git/repo.git").normalizedURLString) == expected
			expect(GitURL("./path/to/git/repo").normalizedURLString) == expected
		}
		
		do {
			let expected = "../path/to/git/repo"
			expect(GitURL("../path/to/git/repo.git").normalizedURLString) == expected
			expect(GitURL("../path/to/git/repo").normalizedURLString) == expected
		}
		
		do {
			let expected = "~/path/to/git/repo"
			expect(GitURL("~/path/to/git/repo.git").normalizedURLString) == expected
			expect(GitURL("~/path/to/git/repo").normalizedURLString) == expected
		}
	}
	
	func testShouldParseScpSyntax() {
		let expected = "github.com/antitypical/Result"
		expect(GitURL("git@github.com:antitypical/Result.git").normalizedURLString) == expected
		expect(GitURL("github.com:antitypical/Result").normalizedURLString) == expected
	}
}
