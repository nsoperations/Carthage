import Foundation
import Nimble
import XCTest

@testable import CarthageKit

class BinaryProjectTests: XCTestCase {
	func testShouldParse() {
		let jsonData = (
			"{" +
				"\"1.0\": \"https://my.domain.com/release/1.0.0/framework.zip\"," +
				"\"1.0.1\": \"https://my.domain.com/release/1.0.1/framework.zip\"" +
			"}"
			).data(using: .utf8)!
		
		let actualBinaryProject = BinaryProject.from(jsonData: jsonData).value
		
		let expectedBinaryProject = BinaryProject(versions: [
			PinnedVersion("1.0"): URL(string: "https://my.domain.com/release/1.0.0/framework.zip")!,
			PinnedVersion("1.0.1"): URL(string: "https://my.domain.com/release/1.0.1/framework.zip")!,
			])
		
		expect(actualBinaryProject) == expectedBinaryProject
	}
	
	func testShouldFailIfStringIsNotJson() {
		let jsonData = "definitely not JSON".data(using: .utf8)!
		
		let actualError = BinaryProject.from(jsonData: jsonData).error
		
		switch actualError {
		case .some(.invalidJSON):
			break
			
		default:
			fail("Expected invalidJSON error")
		}
	}
	
	func testShouldFailIfStringIsNotADictionaryOfStrings() {
		let jsonData = "[\"this\", \"is\", \"not\", \"a\", \"dictionary\"]".data(using: .utf8)!
		
		let actualError = BinaryProject.from(jsonData: jsonData).error
		
		if case let .invalidJSON(underlyingError)? = actualError {
			expect(underlyingError is DecodingError) == true
		} else {
			fail()
		}
	}
	
	func testShouldFailWithAnInvalidSemanticVersion() {
		let jsonData = "{ \"1.a\": \"https://my.domain.com/release/1.0.0/framework.zip\" }".data(using: .utf8)!
		
		let actualError = BinaryProject.from(jsonData: jsonData).error
		
		expect(actualError) == .invalidVersion(ScannableError(message: "expected minor version number", currentLine: "1.a"))
	}
	
	func testShouldFailWithANonParseableUrl() {
		let jsonData = "{ \"1.0\": \"💩\" }".data(using: .utf8)!
		
		let actualError = BinaryProject.from(jsonData: jsonData).error
		
		expect(actualError) == .invalidURL("💩")
	}
	
	func testShouldFailWithANonHttpsUrl() {
		let jsonData = "{ \"1.0\": \"http://my.domain.com/framework.zip\" }".data(using: .utf8)!
		let actualError = BinaryProject.from(jsonData: jsonData).error
		
		expect(actualError) == .nonHTTPSURL(URL(string: "http://my.domain.com/framework.zip")!)
	}
	
	func testShouldParseWithAFileUrl() {
		let jsonData = "{ \"1.0\": \"file:///my/domain/com/framework.zip\" }".data(using: .utf8)!
		let actualBinaryProject = BinaryProject.from(jsonData: jsonData).value
		
		let expectedBinaryProject = BinaryProject(versions: [
			PinnedVersion("1.0"): URL(string: "file:///my/domain/com/framework.zip")!,
			])
		
		expect(actualBinaryProject) == expectedBinaryProject
	}
}
