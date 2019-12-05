//
//  FrameworksTests.swift
//  CarthageKitTests
//
//  Created by Werner Altewischer on 05/09/2019.
//

import XCTest
@testable import CarthageKit

public class FrameworksTests: XCTestCase {

    #if !SWIFT_PACKAGE
    let testSwiftFramework = "Quick.framework"
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let testSwiftFrameworkURL = currentDirectory.appendingPathComponent(testSwiftFramework)
    #endif

    #if !SWIFT_PACKAGE
    func testShouldDetermineThatASwiftFrameworkIsASwiftFramework() {
        expect(isSwiftFramework(testSwiftFrameworkURL)) == true
    }
    #endif

    func testShouldDetermineThatAnObjcFrameworkIsNotASwiftFramework() {
        guard let frameworkURL = Bundle(for: type(of: self)).url(forResource: "FakeOldObjc.framework", withExtension: nil) else {
            XCTFail("Could not load FakeOldObjc.framework from resources")
            return
        }
        XCTAssertFalse(Frameworks.isSwiftFramework(frameworkURL))
    }

    #if !SWIFT_PACKAGE
    func testShouldDetermineAFrameworksSwiftVersion() {
        let result = frameworkSwiftVersion(testSwiftFrameworkURL).single()

        expect(FileManager.default.fileExists(atPath: testSwiftFrameworkURL.path)) == true
        expect(result?.value) == currentSwiftVersion
    }

    func testShouldDetermineADsymsSwiftVersion() {

        let dSYMURL = testSwiftFrameworkURL.appendingPathExtension("dSYM")
        expect(FileManager.default.fileExists(atPath: dSYMURL.path)) == true

        let result = Frameworks.dSYMSwiftVersion(dSYMURL).single()
        expect(result?.value) == currentSwiftVersion
    }
    #endif

    #if !SWIFT_PACKAGE
    func testShouldDetermineWhenASwiftFrameworkIsCompatible() {
        let result = checkSwiftFrameworkCompatibility(testSwiftFrameworkURL, usingToolchain: nil).single()

        expect(result?.value) == testSwiftFrameworkURL
    }
    #endif
    
    func testStripPrivateSymbols() {
        let result = Frameworks.stripPrivateSymbols(for: URL(fileURLWithPath: "/Users/werneraltewischer/Developer/ING/INGStyleKitV2/Carthage/Build/iOS/INGStyleKit.framework/INGStyleKit"))
        
        switch result {
        case .success:
            break
        case let .failure(error):
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testShouldDetermineWhenASwiftFrameworkIsIncompatible() {
        guard let frameworkURL = Bundle(for: type(of: self)).url(forResource: "FakeOldSwift.framework", withExtension: nil) else {
            XCTFail("Could not load FakeOldSwift.framework from resources")
            return
        }

        guard let currentSwiftVersion = SwiftToolchain.swiftVersion().single()?.value else {
            XCTFail("Could not get current swift version")
            return
        }

        guard let frameworkVersion = Frameworks.frameworkSwiftVersion(frameworkURL).single()?.value else {
            XCTFail("Could not get framework swift version")
            return
        }

        let result = Frameworks.checkSwiftFrameworkCompatibility(frameworkURL, usingToolchain: nil).single()

        XCTAssertNil(result?.value)
        XCTAssertEqual(result?.error, .incompatibleFrameworkSwiftVersions(local: currentSwiftVersion, framework: frameworkVersion))
    }

    func testShouldDetermineAFrameworksSwiftVersionForOssToolchainsFromSwiftOrg() {
        guard let frameworkURL = Bundle(for: type(of: self)).url(forResource: "FakeOSSSwift.framework", withExtension: nil) else {
            XCTFail("Could not load FakeOSSSwift.framework from resources")
            return
        }
        let result = Frameworks.frameworkSwiftVersion(frameworkURL).single()

        guard let semanticVersion = result?.value?.semanticVersion else {
            XCTFail("Could not get semantic version")
            return
        }

        let expectedVersion = SemanticVersion(4, 1, 0, prereleaseIdentifiers: ["dev"], buildMetadataIdentifiers: [])
        let semanticVersionWithoutBuildMetaIdentifiers = SemanticVersion(semanticVersion.major, semanticVersion.minor, semanticVersion.patch, prereleaseIdentifiers: semanticVersion.prereleaseIdentifiers, buildMetadataIdentifiers: [])

        XCTAssertEqual(expectedVersion, semanticVersionWithoutBuildMetaIdentifiers)
        XCTAssertFalse(semanticVersion.buildMetadataIdentifiers.isEmpty)
    }

    func testShouldDetermineAFrameworksSwiftVersionExcludingAnEffectiveVersion() {
        guard let frameworkURL = Bundle(for: type(of: self)).url(forResource: "FakeSwift.framework", withExtension: nil) else {
            XCTFail("Could not load FakeSwift.framework from resources")
            return
        }
        let result = Frameworks.frameworkSwiftVersion(frameworkURL).single()

        guard let semanticVersion = result?.value?.semanticVersion else {
            XCTFail("Expected a valid semantic version")
            return
        }

        XCTAssertTrue(semanticVersion.hasSameNumericComponents(version: SemanticVersion(string: "4.0.0")!))
    }

    public func testSwiftCompatibility() throws {

        guard let kingFisherFrameworkURL = Bundle(for: FrameworksTests.self).url(forResource: "Kingfisher", withExtension: "framework") else {
            XCTFail("Could not find Kingfisher framework")
            return
        }

        guard let swiftVersion: PinnedVersion = SwiftToolchain.swiftVersion(from: "Apple Swift version 5.1 (swiftlang-1100.0.270.6 clang-1100.0.32.1)") else {
            XCTFail("Could not parse swift version")
            return
        }

        //Kingfisher version is Apple Swift version 5.1 effective-4.2 (swiftlang-1100.0.266.1 clang-1100.0.32.1)

        guard let result = Frameworks.checkFrameworkCompatibility(kingFisherFrameworkURL, swiftVersion: swiftVersion).single() else {
            XCTFail("Could not find frameworkURL")
            return
        }

        switch result {
        case let .failure(error):
            switch error {
            case let .incompatibleFrameworkSwiftVersions(local: localVersion, framework: frameworkVersion):
                guard let localSemanticVersion = localVersion.semanticVersion,
                    let frameworkSemanticVersion = frameworkVersion.semanticVersion else {
                        XCTFail("Expected semantic version to be valid")
                        return
                }
                XCTAssertTrue(localSemanticVersion.hasSameNumericComponents(version: frameworkSemanticVersion))
            default:
                XCTFail("Expected incompatibleFrameworkSwiftVersions error, but got: \(error)")
            }
        default:
            XCTFail("Expected failure: the framework should not be compatible")
        }
    }
}
