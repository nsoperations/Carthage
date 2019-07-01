@testable import CarthageKit
import Foundation
import Nimble
import XCTest

class VersionTests: XCTestCase {
	func testShouldParseSemanticVersions() {
		expect(PinnedVersion("1.4").semanticVersion) == SemanticVersion(1, 4, 0)
		expect(PinnedVersion("v2.8.9").semanticVersion) == SemanticVersion(2, 8, 9)
		expect(PinnedVersion("2.8.2-alpha").semanticVersion) == SemanticVersion(2, 8, 2, prereleaseIdentifiers: ["alpha"])
		expect(PinnedVersion("2.8.2-alpha+build234").semanticVersion) == SemanticVersion(2, 8, 2, prereleaseIdentifiers: ["alpha"], buildMetadataIdentifiers: ["build234"])
		expect(PinnedVersion("2.8.2+build234").semanticVersion) == SemanticVersion(2, 8, 2, buildMetadataIdentifiers: ["build234"])
		expect(PinnedVersion("2.8.2-alpha.2.1.0").semanticVersion) == SemanticVersion(2, 8, 2, prereleaseIdentifiers: ["alpha", "2", "1", "0"])
        expect(PinnedVersion("v2.8-alpha").semanticVersion) == SemanticVersion(2, 8, 0, prereleaseIdentifiers: ["alpha"])
        expect(PinnedVersion("v2.8+build345").semanticVersion)  == SemanticVersion(2, 8, 0, buildMetadataIdentifiers: ["build345"])
	}
	
	func testShouldFailOnInvalidSemanticVersions() {
		expect(PinnedVersion("release#2").semanticVersion).to(beNil()) // not a valid SemVer
		expect(PinnedVersion("v1").semanticVersion).to(beNil())
		expect(PinnedVersion("null-string-beta-2").semanticVersion).to(beNil())
		expect(PinnedVersion("1.4.5+").semanticVersion).to(beNil()) // missing build metadata after '+'
		expect(PinnedVersion("1.4.5-alpha+").semanticVersion).to(beNil()) // missing build metadata after '+'
		expect(PinnedVersion("1.4.5-alpha#2").semanticVersion).to(beNil()) // non alphanumeric are  not allowed in pre-release
		expect(PinnedVersion("1.4.5-alpha.2.01.0").semanticVersion).to(beNil()) // numeric identifiers in pre-release
		//version must not include leading zeros
		expect(PinnedVersion("1.4.5-alpha.2..0").semanticVersion).to(beNil()) // empty pre-release component
		expect(PinnedVersion("1.4.5+build@2").semanticVersion).to(beNil()) // non alphanumeric are not allowed in build metadata
		expect(PinnedVersion("1.4.5-").semanticVersion).to(beNil()) // missing pre-release after '-'
		expect(PinnedVersion("1.4.5-+build43").semanticVersion).to(beNil()) // missing pre-release after '-'
		expect(PinnedVersion("1.４.5").semanticVersion).to(beNil()) // Note that the `４` in this string is
		// a fullwidth character, not a halfwidth `4`
		expect(PinnedVersion("1.8.0.1").semanticVersion).to(beNil()) // not a valid SemVer, too many dots
		expect(PinnedVersion("1.8..1").semanticVersion).to(beNil()) // not a valid SemVer, double dots
		expect(PinnedVersion("1.8.1.").semanticVersion).to(beNil()) // not a valid SemVer, ends with dot
		expect(PinnedVersion("1.8.").semanticVersion).to(beNil()) // not a valid SemVer, ends with dot
		expect(PinnedVersion("1.").semanticVersion).to(beNil()) // not a valid SemVer, ends with dot
		expect(PinnedVersion("1.8.0.alpha").semanticVersion).to(beNil()) // not a valid SemVer, pre-release is dot-separated
		
	}
}

func testIntersection(_ lhs: VersionSpecifier, _ rhs: VersionSpecifier, expected: VersionSpecifier?) {
	if let expected = expected {
		expect(VersionSpecifier.intersection(lhs, rhs)) == expected
		expect(VersionSpecifier.intersection(rhs, lhs)) == expected
	} else {
		expect(VersionSpecifier.intersection(lhs, rhs)).to(beNil())
		expect(VersionSpecifier.intersection(rhs, lhs)).to(beNil())
	}
}

class VersionSpecifierIsSatisfiedByTests: XCTestCase {
	
	let v0_1_0 = PinnedVersion("0.1.0")
	let v0_1_0_pre23 = PinnedVersion("0.1.0-pre23")
	let v0_1_0_build123 = PinnedVersion("v0.1.0+build123")
	let v0_1_1 = PinnedVersion("0.1.1")
	let v0_2_0 = PinnedVersion("0.2.0")
	let v0_2_0_candidate = PinnedVersion("0.2.0-candidate")
	let v1_3_2 = PinnedVersion("1.3.2")
	let v2_0_2 = PinnedVersion("2.0.2")
	let v2_1_1 = PinnedVersion("2.1.1")
	let v2_1_1_build3345 = PinnedVersion("2.1.1+build3345")
	let v2_1_1_alpha = PinnedVersion("2.1.1-alpha")
	let v2_2_0 = PinnedVersion("2.2.0")
	let v3_0_0 = PinnedVersion("3.0.0")
	let nonSemantic = PinnedVersion("new-version")
	
	func testShouldAllowAllVersionsForAny() {
		let specifier = VersionSpecifier.any
		expect(specifier.isSatisfied(by: self.v1_3_2)) == true
		expect(specifier.isSatisfied(by: self.v2_0_2)) == true
		expect(specifier.isSatisfied(by: self.v2_1_1)) == true
		expect(specifier.isSatisfied(by: self.v2_2_0)) == true
		expect(specifier.isSatisfied(by: self.v3_0_0)) == true
		expect(specifier.isSatisfied(by: self.v0_1_0)) == true
		expect(specifier.isSatisfied(by: self.v0_1_0_build123)) == true
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == true
	}
	
	func testShouldAllowANonSemanticVersionForAny() {
		let specifier = VersionSpecifier.any
		expect(specifier.isSatisfied(by: self.nonSemantic)) == true
	}
	
	func testShouldNotAllowAPreReleaseVersionForAny() {
		let specifier = VersionSpecifier.any
		expect(specifier.isSatisfied(by: self.v2_1_1_alpha)) == false
	}
	
	func testShouldAllowGreaterOrEqualVersionsForAtleast() {
		let specifier = VersionSpecifier.atLeast(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v1_3_2)) == false
		expect(specifier.isSatisfied(by: self.v2_0_2)) == false
		expect(specifier.isSatisfied(by: self.v2_1_1)) == true
		expect(specifier.isSatisfied(by: self.v2_2_0)) == true
		expect(specifier.isSatisfied(by: self.v3_0_0)) == true
	}
	
	func testShouldAllowANonSemanticVersionForAtleast() {
		let specifier = VersionSpecifier.atLeast(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.nonSemantic)) == true
	}
	
	func testShouldNotAllowForAPreReleaseOfTheSameNonPreReleaseVersionForAtleast()
	{
		let specifier = VersionSpecifier.atLeast(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v2_1_1_alpha)) == false
	}
	
	func testShouldAllowForABuildVersionOfTheSameVersionForAtleast()
	{
		let specifier = VersionSpecifier.atLeast(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == true
	}
	
	func testShouldNotAllowForABuildVersionOfADifferentVersionForAtleast()
	{
		let specifier = VersionSpecifier.atLeast(v3_0_0.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == false
	}
	
	func testShouldAllowForABuildVersionOfTheSameVersionForCompatiblewith()
	{
		let specifier = VersionSpecifier.compatibleWith(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == true
	}
	
	func testShouldNotAllowForABuildVersionOfADifferentVersionForCompatiblewith()
	{
		let specifier = VersionSpecifier.compatibleWith(v1_3_2.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == false
	}
	
	func testShouldNotAllowForAGreaterPreReleaseVersionForAtleast() {
		let specifier = VersionSpecifier.atLeast(v2_0_2.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v2_1_1_alpha)) == false
	}
	
	func testShouldAllowGreaterOrEqualMinorAndPatchVersionsForCompatiblewith() {
		let specifier = VersionSpecifier.compatibleWith(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v1_3_2)) == false
		expect(specifier.isSatisfied(by: self.v2_0_2)) == false
		expect(specifier.isSatisfied(by: self.v2_1_1)) == true
		expect(specifier.isSatisfied(by: self.v2_2_0)) == true
		expect(specifier.isSatisfied(by: self.v3_0_0)) == false
	}
	
	func testShouldAllowANonSemanticVersionForCompatiblewith() {
		let specifier = VersionSpecifier.compatibleWith(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.nonSemantic)) == true
	}
	
	func testShouldNotAllowEqualMinorAndPatchPreReleaseVersionForCompatiblewith() {
		let specifier = VersionSpecifier.compatibleWith(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v2_1_1_alpha)) == false
	}
	
	
	func testShouldOnlyAllowExactVersionsForExactly() {
		let specifier = VersionSpecifier.exactly(v2_2_0.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v1_3_2)) == false
		expect(specifier.isSatisfied(by: self.v2_0_2)) == false
		expect(specifier.isSatisfied(by: self.v2_1_1)) == false
		expect(specifier.isSatisfied(by: self.v2_2_0)) == true
		expect(specifier.isSatisfied(by: self.v3_0_0)) == false
	}
	
	func testShouldNotAllowABuildVersionOfADifferentVersionForExactly() {
		let specifier = VersionSpecifier.exactly(v1_3_2.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v0_1_0_build123)) == false
	}
	
	func testShouldNotAllowABuildVersionOfTheSameVersionForExactly() {
		let specifier = VersionSpecifier.exactly(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == false
	}
	
	func testShouldAllowForANonSemanticVersionForExactly() {
		let specifier = VersionSpecifier.exactly(v2_1_1.semanticVersion!)
		expect(specifier.isSatisfied(by: self.nonSemantic)) == true
	}
	
	func testShouldNotAllowAnyPreReleaseVersionsToSatisfy0X() {
		let specifier = VersionSpecifier.compatibleWith(v0_1_0.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v0_1_0_pre23)) == false
	}
	
	func testShouldNotAllowAPreReleaseVersionsOfADifferentVersionToSatisfy0X() {
		let specifier = VersionSpecifier.compatibleWith(v0_1_0.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v0_2_0_candidate)) == false
	}
	
	func testShouldAllowOnlyGreaterPatchVersionsToSatisfy0X() {
		let specifier = VersionSpecifier.compatibleWith(v0_1_0.semanticVersion!)
		expect(specifier.isSatisfied(by: self.v0_1_0)) == true
		expect(specifier.isSatisfied(by: self.v0_1_1)) == true
		expect(specifier.isSatisfied(by: self.v0_2_0)) == false
	}
}

class VersionSpecifierIntersectionTests: XCTestCase {
	let v0_1_0 = SemanticVersion(0, 1, 0)
	let v0_1_1 = SemanticVersion(0, 1, 1)
	let v0_2_0 = SemanticVersion(0, 2, 0)
	let v1_3_2 = SemanticVersion(1, 3, 2)
	let v2_1_1 = SemanticVersion(2, 1, 1)
	let v2_2_0 = SemanticVersion(2, 2, 0)
	let v2_2_0_b421 = SemanticVersion(2, 2, 0, buildMetadataIdentifiers: ["b421"])
	let v2_2_0_alpha = SemanticVersion(2, 2, 0, prereleaseIdentifiers: ["alpha"])
	
	func testShouldReturnTheTighterSpecifierWhenOneIsAny() {
		testIntersection(.any, .any, expected: .any)
		testIntersection(.any, .atLeast(v1_3_2), expected: .atLeast(v1_3_2))
		testIntersection(.any, .compatibleWith(v1_3_2), expected: .compatibleWith(v1_3_2))
		testIntersection(.any, .exactly(v1_3_2), expected: .exactly(v1_3_2))
		testIntersection(.any, .exactly(v2_2_0_b421), expected: .exactly(v2_2_0_b421))
		testIntersection(.any, .exactly(v2_2_0_alpha), expected: .exactly(v2_2_0_alpha))
	}
	
	func testShouldReturnTheHigherSpecifierWhenOneIsAtleast() {
		testIntersection(.atLeast(v1_3_2), .atLeast(v1_3_2), expected: .atLeast(v1_3_2))
		testIntersection(.atLeast(v1_3_2), .atLeast(v2_1_1), expected: .atLeast(v2_1_1))
		testIntersection(.atLeast(v2_2_0), .atLeast(v2_2_0_b421), expected: .atLeast(v2_2_0))
		testIntersection(.atLeast(v2_2_0), .atLeast(v2_2_0_alpha), expected: .atLeast(v2_2_0))
		testIntersection(.atLeast(v1_3_2), .compatibleWith(v2_1_1), expected: .compatibleWith(v2_1_1))
		testIntersection(.atLeast(v2_1_1), .compatibleWith(v2_2_0), expected: .compatibleWith(v2_2_0))
		testIntersection(.atLeast(v2_2_0), .compatibleWith(v2_2_0_b421), expected: .compatibleWith(v2_2_0))
		testIntersection(.atLeast(v2_2_0), .compatibleWith(v2_2_0_alpha), expected: .compatibleWith(v2_2_0))
		testIntersection(.atLeast(v2_2_0_alpha), .compatibleWith(v2_2_0), expected: .compatibleWith(v2_2_0))
		testIntersection(.atLeast(v1_3_2), .exactly(v2_2_0), expected: .exactly(v2_2_0))
		testIntersection(.atLeast(v2_2_0), .exactly(v2_2_0_b421), expected: .exactly(v2_2_0_b421))
		testIntersection(.atLeast(v2_2_0_b421), .exactly(v2_2_0), expected: .exactly(v2_2_0))
		testIntersection(.atLeast(v2_2_0_alpha), .exactly(v2_2_0), expected: .exactly(v2_2_0))
	}
	
	func testShouldReturnTheHigherMinorOrPatchVersionWhenOneIsCompatiblewith() {
		testIntersection(.compatibleWith(v1_3_2), .compatibleWith(v1_3_2), expected: .compatibleWith(v1_3_2))
		testIntersection(.compatibleWith(v1_3_2), .compatibleWith(v2_1_1), expected: .empty)
		testIntersection(.compatibleWith(v2_1_1), .compatibleWith(v2_2_0), expected: .compatibleWith(v2_2_0))
		testIntersection(.compatibleWith(v2_1_1), .exactly(v2_2_0), expected: .exactly(v2_2_0))
		testIntersection(.compatibleWith(v2_2_0), .exactly(v2_2_0_alpha), expected: .empty)
		testIntersection(.compatibleWith(v2_2_0), .exactly(v2_2_0_b421), expected: .exactly(v2_2_0_b421))
		testIntersection(.compatibleWith(v2_2_0_alpha), .exactly(v2_2_0), expected: .exactly(v2_2_0))
		testIntersection(.compatibleWith(v2_2_0_b421), .exactly(v2_2_0), expected: .exactly(v2_2_0))
	}
	
	func testShouldOnlyMatchExactSpecifiersForExactly() {
		testIntersection(.exactly(v1_3_2), .atLeast(v2_1_1), expected: .empty)
		testIntersection(.exactly(v2_1_1), .compatibleWith(v1_3_2), expected: .empty)
		testIntersection(.exactly(v2_1_1), .compatibleWith(v2_2_0), expected: .empty)
		testIntersection(.exactly(v1_3_2), .exactly(v1_3_2), expected: VersionSpecifier.exactly(v1_3_2))
		testIntersection(.exactly(v2_1_1), .exactly(v1_3_2), expected: .empty)
		testIntersection(.exactly(v2_2_0_alpha), .exactly(v2_2_0), expected: .empty)
		testIntersection(.exactly(v2_2_0_b421), .exactly(v2_2_0), expected: .empty)
	}
	
	func testShouldLet011BeCompatibleWith012ButNot02() {
		testIntersection(.compatibleWith(v0_1_0), .compatibleWith(v0_1_1), expected: .compatibleWith(v0_1_1))
		testIntersection(.compatibleWith(v0_1_0), .compatibleWith(v0_2_0), expected: .empty)
	}
}
