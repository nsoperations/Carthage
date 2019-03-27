import CarthageKit
import Foundation
import Nimble
import XCTest
import SPMUtility

class VersionTests: XCTestCase {
	func testShouldParseSemanticVersions() {
		expect(Version.from(PinnedVersion("1.4")).value) == Version(1, 4, 0)
		expect(Version.from(PinnedVersion("v2.8.9")).value) == Version(2, 8, 9)
		expect(Version.from(PinnedVersion("2.8.2-alpha")).value) == Version(2, 8, 2, prereleaseIdentifiers: ["alpha"])
		expect(Version.from(PinnedVersion("2.8.2-alpha+build234")).value) == Version(2, 8, 2, prereleaseIdentifiers: ["alpha"], buildMetadataIdentifiers: ["build234"])
		expect(Version.from(PinnedVersion("2.8.2+build234")).value) == Version(2, 8, 2, buildMetadataIdentifiers: ["build234"])
		expect(Version.from(PinnedVersion("2.8.2-alpha.2.1.0")).value) == Version(2, 8, 2, prereleaseIdentifiers: ["alpha", "2", "1", "0"])
	}
	
	func testShouldFailOnInvalidSemanticVersions() {
		expect(Version.from(PinnedVersion("release#2")).value).to(beNil()) // not a valid SemVer
		expect(Version.from(PinnedVersion("v1")).value).to(beNil())
		expect(Version.from(PinnedVersion("v2.8-alpha")).value).to(beNil()) // pre-release should be after patch
		expect(Version.from(PinnedVersion("v2.8+build345")).value).to(beNil()) // build should be after patch
		expect(Version.from(PinnedVersion("null-string-beta-2")).value).to(beNil())
		expect(Version.from(PinnedVersion("1.4.5+")).value).to(beNil()) // missing build metadata after '+'
		expect(Version.from(PinnedVersion("1.4.5-alpha+")).value).to(beNil()) // missing build metadata after '+'
		expect(Version.from(PinnedVersion("1.4.5-alpha#2")).value).to(beNil()) // non alphanumeric are  not allowed in pre-release
		expect(Version.from(PinnedVersion("1.4.5-alpha.2.01.0")).value).to(beNil()) // numeric identifiers in pre-release
		//version must not include leading zeros
		expect(Version.from(PinnedVersion("1.4.5-alpha.2..0")).value).to(beNil()) // empty pre-release component
		expect(Version.from(PinnedVersion("1.4.5+build@2")).value).to(beNil()) // non alphanumeric are not allowed in build metadata
		expect(Version.from(PinnedVersion("1.4.5-")).value).to(beNil()) // missing pre-release after '-'
		expect(Version.from(PinnedVersion("1.4.5-+build43")).value).to(beNil()) // missing pre-release after '-'
		expect(Version.from(PinnedVersion("1.４.5")).value).to(beNil()) // Note that the `４` in this string is
		// a fullwidth character, not a halfwidth `4`
		expect(Version.from(PinnedVersion("1.8.0.1")).value).to(beNil()) // not a valid SemVer, too many dots
		expect(Version.from(PinnedVersion("1.8..1")).value).to(beNil()) // not a valid SemVer, double dots
		expect(Version.from(PinnedVersion("1.8.1.")).value).to(beNil()) // not a valid SemVer, ends with dot
		expect(Version.from(PinnedVersion("1.8.")).value).to(beNil()) // not a valid SemVer, ends with dot
		expect(Version.from(PinnedVersion("1.")).value).to(beNil()) // not a valid SemVer, ends with dot
		expect(Version.from(PinnedVersion("1.8.0.alpha")).value).to(beNil()) // not a valid SemVer, pre-release is dot-separated
		
	}
}

func testIntersection(_ lhs: VersionSpecifier, _ rhs: VersionSpecifier, expected: VersionSpecifier?) {
	if let expected = expected {
		expect(intersection(lhs, rhs)) == expected
		expect(intersection(rhs, lhs)) == expected
	} else {
		expect(intersection(lhs, rhs)).to(beNil())
		expect(intersection(rhs, lhs)).to(beNil())
	}
}

class VersionSpecifierTests1: XCTestCase {
	
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
		let specifier = VersionSpecifier.atLeast(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.v1_3_2)) == false
		expect(specifier.isSatisfied(by: self.v2_0_2)) == false
		expect(specifier.isSatisfied(by: self.v2_1_1)) == true
		expect(specifier.isSatisfied(by: self.v2_2_0)) == true
		expect(specifier.isSatisfied(by: self.v3_0_0)) == true
	}
	
	func testShouldAllowANonSemanticVersionForAtleast() {
		let specifier = VersionSpecifier.atLeast(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.nonSemantic)) == true
	}
	
	func testShouldNotAllowForAPreReleaseOfTheSameNonPreReleaseVersionForAtleast()
	{
		let specifier = VersionSpecifier.atLeast(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.v2_1_1_alpha)) == false
	}
	
	func testShouldAllowForABuildVersionOfTheSameVersionForAtleast()
	{
		let specifier = VersionSpecifier.atLeast(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == true
	}
	
	func testShouldNotAllowForABuildVersionOfADifferentVersionForAtleast()
	{
		let specifier = VersionSpecifier.atLeast(Version.from(v3_0_0).value!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == false
	}
	
	func testShouldAllowForABuildVersionOfTheSameVersionForCompatiblewith()
	{
		let specifier = VersionSpecifier.compatibleWith(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == true
	}
	
	func testShouldNotAllowForABuildVersionOfADifferentVersionForCompatiblewith()
	{
		let specifier = VersionSpecifier.compatibleWith(Version.from(v1_3_2).value!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == false
	}
	
	func testShouldNotAllowForAGreaterPreReleaseVersionForAtleast() {
		let specifier = VersionSpecifier.atLeast(Version.from(v2_0_2).value!)
		expect(specifier.isSatisfied(by: self.v2_1_1_alpha)) == false
	}
	
	func testShouldAllowGreaterOrEqualMinorAndPatchVersionsForCompatiblewith() {
		let specifier = VersionSpecifier.compatibleWith(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.v1_3_2)) == false
		expect(specifier.isSatisfied(by: self.v2_0_2)) == false
		expect(specifier.isSatisfied(by: self.v2_1_1)) == true
		expect(specifier.isSatisfied(by: self.v2_2_0)) == true
		expect(specifier.isSatisfied(by: self.v3_0_0)) == false
	}
	
	func testShouldAllowANonSemanticVersionForCompatiblewith() {
		let specifier = VersionSpecifier.compatibleWith(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.nonSemantic)) == true
	}
	
	func testShouldNotAllowEqualMinorAndPatchPreReleaseVersionForCompatiblewith() {
		let specifier = VersionSpecifier.compatibleWith(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.v2_1_1_alpha)) == false
	}
	
	
	func testShouldOnlyAllowExactVersionsForExactly() {
		let specifier = VersionSpecifier.exactly(Version.from(v2_2_0).value!)
		expect(specifier.isSatisfied(by: self.v1_3_2)) == false
		expect(specifier.isSatisfied(by: self.v2_0_2)) == false
		expect(specifier.isSatisfied(by: self.v2_1_1)) == false
		expect(specifier.isSatisfied(by: self.v2_2_0)) == true
		expect(specifier.isSatisfied(by: self.v3_0_0)) == false
	}
	
	func testShouldNotAllowABuildVersionOfADifferentVersionForExactly() {
		let specifier = VersionSpecifier.exactly(Version.from(v1_3_2).value!)
		expect(specifier.isSatisfied(by: self.v0_1_0_build123)) == false
	}
	
	func testShouldNotAllowABuildVersionOfTheSameVersionForExactly() {
		let specifier = VersionSpecifier.exactly(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.v2_1_1_build3345)) == false
	}
	
	func testShouldAllowForANonSemanticVersionForExactly() {
		let specifier = VersionSpecifier.exactly(Version.from(v2_1_1).value!)
		expect(specifier.isSatisfied(by: self.nonSemantic)) == true
	}
	
	func testShouldNotAllowAnyPreReleaseVersionsToSatisfy0X() {
		let specifier = VersionSpecifier.compatibleWith(Version.from(v0_1_0).value!)
		expect(specifier.isSatisfied(by: self.v0_1_0_pre23)) == false
	}
	
	func testShouldNotAllowAPreReleaseVersionsOfADifferentVersionToSatisfy0X() {
		let specifier = VersionSpecifier.compatibleWith(Version.from(v0_1_0).value!)
		expect(specifier.isSatisfied(by: self.v0_2_0_candidate)) == false
	}
	
	func testShouldAllowOnlyGreaterPatchVersionsToSatisfy0X() {
		let specifier = VersionSpecifier.compatibleWith(Version.from(v0_1_0).value!)
		expect(specifier.isSatisfied(by: self.v0_1_0)) == true
		expect(specifier.isSatisfied(by: self.v0_1_1)) == true
		expect(specifier.isSatisfied(by: self.v0_2_0)) == false
	}
}

class VersionSpecifierTests2: XCTestCase {
	let v0_1_0 = Version(0, 1, 0)
	let v0_1_1 = Version(0, 1, 1)
	let v0_2_0 = Version(0, 2, 0)
	let v1_3_2 = Version(1, 3, 2)
	let v2_1_1 = Version(2, 1, 1)
	let v2_2_0 = Version(2, 2, 0)
	let v2_2_0_b421 = Version(2, 2, 0, buildMetadataIdentifiers: ["b421"])
	let v2_2_0_alpha = Version(2, 2, 0, prereleaseIdentifiers: ["alpha"])
	
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
		testIntersection(.compatibleWith(v1_3_2), .compatibleWith(v2_1_1), expected: nil)
		testIntersection(.compatibleWith(v2_1_1), .compatibleWith(v2_2_0), expected: .compatibleWith(v2_2_0))
		testIntersection(.compatibleWith(v2_1_1), .exactly(v2_2_0), expected: .exactly(v2_2_0))
		testIntersection(.compatibleWith(v2_2_0), .exactly(v2_2_0_alpha), expected: nil)
		testIntersection(.compatibleWith(v2_2_0), .exactly(v2_2_0_b421), expected: .exactly(v2_2_0_b421))
		testIntersection(.compatibleWith(v2_2_0_alpha), .exactly(v2_2_0), expected: .exactly(v2_2_0))
		testIntersection(.compatibleWith(v2_2_0_b421), .exactly(v2_2_0), expected: .exactly(v2_2_0))
	}
	
	func testShouldOnlyMatchExactSpecifiersForExactly() {
		testIntersection(.exactly(v1_3_2), .atLeast(v2_1_1), expected: nil)
		testIntersection(.exactly(v2_1_1), .compatibleWith(v1_3_2), expected: nil)
		testIntersection(.exactly(v2_1_1), .compatibleWith(v2_2_0), expected: nil)
		testIntersection(.exactly(v1_3_2), .exactly(v1_3_2), expected: VersionSpecifier.exactly(v1_3_2))
		testIntersection(.exactly(v2_1_1), .exactly(v1_3_2), expected: nil)
		testIntersection(.exactly(v2_2_0_alpha), .exactly(v2_2_0), expected: nil)
		testIntersection(.exactly(v2_2_0_b421), .exactly(v2_2_0), expected: nil)
	}
	
	func testShouldLet011BeCompatibleWith012ButNot02() {
		testIntersection(.compatibleWith(v0_1_0), .compatibleWith(v0_1_1), expected: .compatibleWith(v0_1_1))
		testIntersection(.compatibleWith(v0_1_0), .compatibleWith(v0_2_0), expected: nil)
	}
}
