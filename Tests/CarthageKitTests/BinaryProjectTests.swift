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
		
		let expectedBinaryProject = BinaryProject(urls: [
			PinnedVersion("1.0"): URL(string: "https://my.domain.com/release/1.0.0/framework.zip")!,
			PinnedVersion("1.0.1"): URL(string: "https://my.domain.com/release/1.0.1/framework.zip")!,
			])
		
		expect(actualBinaryProject) == expectedBinaryProject
	}

    func testShouldParseExtendedFormat() {
        let jsonData = (
            """
            {
                "1.0": [
                    {"url": "https://my.domain.com/release/1.0.0/framework-debug-4.2.zip", "configuration": "Debug", "swiftVersion": "4.2"},
                    {"url": "https://my.domain.com/release/1.0.0/framework-release-4.2.zip", "configuration": "Release", "swiftVersion": "4.2"},
                    {"url": "https://my.domain.com/release/1.0.0/framework-debug-5.0.zip", "configuration": "Debug", "swiftVersion": "5.0"},
                    {"url": "https://my.domain.com/release/1.0.0/framework-release-5.0.zip", "configuration": "Release", "swiftVersion": "5.0"}
                ],
                "1.0.1": [
                    {"url": "https://my.domain.com/release/1.0.1/framework-debug.zip", "configuration": "Debug"},
                    {"url": "https://my.domain.com/release/1.0.1/framework-release.zip"},
                ]
            }
            """
            ).data(using: .utf8)!

        do {

            let actualBinaryProject = try BinaryProject.from(jsonData: jsonData).get()
            let expectedBinaryProject = BinaryProject(definitions: [
                PinnedVersion("1.0"): [
                    BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-debug-4.2.zip")!, configuration: "Debug", swiftVersion: PinnedVersion("4.2")),
                    BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-release-4.2.zip")!, configuration: "Release", swiftVersion: PinnedVersion("4.2")),
                    BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-debug-5.0.zip")!, configuration: "Debug", swiftVersion: PinnedVersion("5.0")),
                    BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-release-5.0.zip")!, configuration: "Release", swiftVersion: PinnedVersion("5.0"))
                ],
                PinnedVersion("1.0.1"): [
                    BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.1/framework-debug.zip")!, configuration: "Debug", swiftVersion: nil),
                    BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.1/framework-release.zip")!, configuration: nil, swiftVersion: nil),
                ]
                ])


            expect(actualBinaryProject) == expectedBinaryProject

        } catch {
            fail("Unexpected error thrown: \(error)")
        }
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
		
		if case .invalidJSON(_)? = actualError {
			//OK
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
		
		let expectedBinaryProject = BinaryProject(urls: [
			PinnedVersion("1.0"): URL(string: "file:///my/domain/com/framework.zip")!,
			])
		
		expect(actualBinaryProject) == expectedBinaryProject
	}

    func testGetBinaryURL() {
        let binaryProject = BinaryProject(definitions: [
            PinnedVersion("1.0"): [
                BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-debug-4.2.zip")!, configuration: "Debug", swiftVersion: PinnedVersion("4.2")),
                BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-release-4.2.zip")!, configuration: "Release", swiftVersion: PinnedVersion("4.2")),
                BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-debug-5.0.zip")!, configuration: "Debug", swiftVersion: PinnedVersion("5.0")),
                BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-release-5.0.zip")!, configuration: "Release", swiftVersion: PinnedVersion("5.0"))
            ],
            PinnedVersion("1.0.1"): [
                BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-debug.zip")!, configuration: "Debug", swiftVersion: nil),
                BinaryProjectFile(url: URL(string: "https://my.domain.com/release/1.0.0/framework-release.zip")!, configuration: nil, swiftVersion: nil),
            ]
            ])


        //Non existent pinned version
        XCTAssertNil(binaryProject.binaryURL(for: PinnedVersion("2.0"), configuration: "Debug", swiftVersion: PinnedVersion("5.0")))

        //Non existent configuration
        XCTAssertNil(binaryProject.binaryURL(for: PinnedVersion("1.0"), configuration: "Debug1", swiftVersion: PinnedVersion("5.0")))

        //Non existent swift version
        XCTAssertNil(binaryProject.binaryURL(for: PinnedVersion("1.0"), configuration: "Debug", swiftVersion: PinnedVersion("3.0")))

        XCTAssertNotNil(binaryProject.binaryURL(for: PinnedVersion("1.0"), configuration: "Debug", swiftVersion: PinnedVersion("4.2")))
        XCTAssertNotNil(binaryProject.binaryURL(for: PinnedVersion("1.0"), configuration: "Debug", swiftVersion: PinnedVersion("5.0")))
        XCTAssertNotNil(binaryProject.binaryURL(for: PinnedVersion("1.0"), configuration: "Release", swiftVersion: PinnedVersion("5.0")))
    }
}
