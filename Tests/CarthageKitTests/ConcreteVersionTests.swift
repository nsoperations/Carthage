import Foundation
import XCTest
import BTree
@testable import CarthageKit

class ConcreteVersionTests: XCTestCase {
	
	func testConcreteVersionOrdering() {
		let versions = [
			"3.10.0",
			"2.2.1",
			"2.1.5",
			"2.0.0",
			"2.0.0-beta.2",
			"2.0.0-beta.1",
			"2.0.0-alpha.1",
			"1.5.2",
			"1.4.9",
			"1.0.0",
			"0.5.2",
			"0.5.0",
			"0.4.10",
			"0.0.5",
			"0.0.1",
			"1234567890abcdef",
			"fedcba0987654321",
			]
		
		let shuffledVersions = versions.shuffled()
		var set = SortedSet<ConcreteVersion>()
		
		for versionString in shuffledVersions {
			let pinnedVersion = PinnedVersion(versionString)
			XCTAssertTrue(set.insert(ConcreteVersion(pinnedVersion: pinnedVersion)).inserted)
		}
		
		let orderedVersions = Array(set).map { return $0.pinnedVersion.commitish }
		
		XCTAssertEqual(versions, orderedVersions)
	}
	
	func testConcreteVersionComparison() {
		var v1 = ConcreteVersion(string: "1.0.0")
		var v2 = ConcreteVersion(string: "1.1.0")
		
		XCTAssertTrue(v2 < v1)
		XCTAssertTrue(v1 > v2)
		XCTAssertTrue(v2 <= v1)
		XCTAssertTrue(v1 >= v2)
		
		v1 = ConcreteVersion(string: "aap")
		v2 = ConcreteVersion(string: "1.0.0")
		
		XCTAssertTrue(v2 < v1)
		XCTAssertTrue(v1 > v2)
		XCTAssertTrue(v2 <= v1)
		XCTAssertTrue(v1 >= v2)
		
		v1 = ConcreteVersion(string: "1.0.0-alpha.1")
		v2 = ConcreteVersion(string: "1.0.0")
		
		XCTAssertTrue(v1.semanticVersion?.isPreRelease ?? false)
		XCTAssertFalse(v2.semanticVersion?.isPreRelease ?? true)
		
		XCTAssertEqual(v1.semanticVersion?.prereleaseIdentifiers, ["alpha", "1"])
		
		XCTAssertTrue(v2 < v1)
		XCTAssertTrue(v1 > v2)
		XCTAssertTrue(v2 <= v1)
		XCTAssertTrue(v1 >= v2)
	}
	
	private func assertVersionSetFilteredCorrectly(set: ConcreteVersionSet, versionSpecifier: VersionSpecifier) {
		let referenceResult = set.filteredVersionsReference(compatibleWith: versionSpecifier)
		let copiedSet = set.copy
		copiedSet.retainVersions(compatibleWith: versionSpecifier)
		XCTAssertEqual(referenceResult, Array(copiedSet), "Failed for versionSpecifier: \(versionSpecifier)")
	}
	
	func testRetainVersions() {
		
		let versions = [
			"3.10.0",
			"2.2.1",
			"2.1.5",
			"2.0.0",
			"2.0.0-beta.1",
			"2.0.0-alpha.1",
			"1.5.2",
			"1.4.9",
			"1.0.0",
			"0.8.0",
			"0.5.2",
			"0.5.0",
			"0.4.10",
			"0.0.5",
			"0.0.1",
			"1234567890abcdef",
			"fedcba0987654321",
			]
		
		let set = ConcreteVersionSet()
		
		for versionString in versions {
			XCTAssertTrue(set.insert(ConcreteVersion(string: versionString)))
		}
		
		let versionSpecifiers = [
			VersionSpecifier.any,
			VersionSpecifier.atLeast(SemanticVersion(1, 0, 0)),
			VersionSpecifier.atLeast(SemanticVersion(1, 0, 1)),
			VersionSpecifier.atLeast(SemanticVersion(0, 9, 0)),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["alpha"])),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["alpha", "1"])),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["beta"])),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["beta", "1"])),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0)),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["beta", "1"])),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["beta"])),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["alpha"])),
			VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["alpha", "1"])),
			VersionSpecifier.compatibleWith(SemanticVersion(1, 0, 0)),
			VersionSpecifier.compatibleWith(SemanticVersion(1, 0, 1)),
			VersionSpecifier.compatibleWith(SemanticVersion(0, 5, 0)),
			VersionSpecifier.compatibleWith(SemanticVersion(0, 5, 1)),
			VersionSpecifier.compatibleWith(SemanticVersion(3, 1, 0)),
			VersionSpecifier.exactly(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["alpha"])),
			VersionSpecifier.exactly(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["alpha", "1"])),
			VersionSpecifier.exactly(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["beta"])),
			VersionSpecifier.exactly(SemanticVersion(2, 0, 0, prereleaseIdentifiers: ["beta", "1"])),
			VersionSpecifier.exactly(SemanticVersion(0, 5, 0)),
			VersionSpecifier.exactly(SemanticVersion(0, 5, 1)),
		]
		
		versionSpecifiers.forEach {
				assertVersionSetFilteredCorrectly(set: set, versionSpecifier: $0)
		}
	}
}

extension MutableCollection {
	/// Shuffles the contents of this collection.
	fileprivate mutating func shuffle() {
		let c = count
		guard c > 1 else { return }
		
		for (firstUnshuffled, unshuffledCount) in zip(indices, stride(from: c, to: 1, by: -1)) {
			let d: Int = numericCast(arc4random_uniform(numericCast(unshuffledCount)))
			let i = index(firstUnshuffled, offsetBy: d)
			swapAt(firstUnshuffled, i)
		}
	}
}

extension Sequence {
	/// Returns an array with the contents of this sequence, shuffled.
	fileprivate func shuffled() -> [Element] {
		var result = Array(self)
		result.shuffle()
		return result
	}
}

extension ConcreteVersionSet {
	func filteredVersionsReference(compatibleWith versionSpecifier: VersionSpecifier) -> [ConcreteVersion] {
		return self.filter { versionSpecifier.isSatisfied(by: $0.pinnedVersion) }.sorted()
	}
}
