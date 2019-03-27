import Foundation
import XCTest
import Nimble

class FrameworkExtensionsTests: XCTestCase {
	
	var parentDirUnderTmp: URL!
	var childDirUnderPrivateTmp: URL!
	
	override func setUp() {
		let baseName = "/tmp/CarthageKitTests-URL-hasSubdirectory"
		parentDirUnderTmp = URL(fileURLWithPath: baseName)
		childDirUnderPrivateTmp = URL(fileURLWithPath: "/private\(baseName)/foo")
		_ = try? FileManager.default
			.createDirectory(at: childDirUnderPrivateTmp, withIntermediateDirectories: true)
	}
	
	override func tearDown() {
		_ = try? FileManager.default
			.removeItem(at: parentDirUnderTmp)
	}
	
	func testShouldFigureOutIfAIsASubdirectoryOfB() {
		let subject = URL(string: "file:///foo/bar")!

		let unrelatedScheme = URL(string: "http:///foo/bar/baz")!
		let parentDir = URL(string: "file:///foo")!
		let immediateSub = URL(string: "file:///foo/bar/baz")!
		let distantSub = URL(string: "file:///foo/bar/baz/qux")!
		let unrelatedDirectory = URL(string: "file:///bar/bar/baz")!

		expect(subject.hasSubdirectory(subject)) == true
		expect(subject.hasSubdirectory(unrelatedScheme)) == false
		expect(subject.hasSubdirectory(parentDir)) == false
		expect(subject.hasSubdirectory(immediateSub)) == true
		expect(subject.hasSubdirectory(distantSub)) == true
		expect(subject.hasSubdirectory(unrelatedDirectory)) == false
	}

	func testShouldResolveTheDifferenceBetweenTmpAndPrivateTmp() {
		expect(self.parentDirUnderTmp.hasSubdirectory(self.childDirUnderPrivateTmp)) == true
	}
	
}
