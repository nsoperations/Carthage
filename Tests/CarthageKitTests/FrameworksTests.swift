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
    
    func testParseDefinedSymbols() {
        let string = "00000000000a9190 T _$s11INGStyleKit14IconCharactersC27lineiconMultiplyCrossXCloseSo7UIImageCvau"
        let scanner = Scanner(string: string)
        scanner.charactersToBeSkipped = CharacterSet()
        
        var scanned: (String, String)?
        var count = 0
        
        /// hex, whitespace, string, whitespace, symbol
        if scanner.scanHexInt64(nil),
            scanner.scanCharacters(from: .whitespaces, into: nil),
            scanner.scanCharacters(from: .alphanumerics, into: nil),
            scanner.scanCharacters(from: .whitespaces, into: nil),
            let symbolName = scanner.remainingSubstring.map(String.init),
            scanner.scanString("_$s", into: nil),
            scanner.scanInt(&count),
            let moduleName = scanner.scan(count: count) {
            
            scanned = (moduleName, symbolName)
            
        }
                
        XCTAssertEqual(scanned?.0, "INGStyleKit")
        XCTAssertEqual(scanned?.1, "_$s11INGStyleKit14IconCharactersC27lineiconMultiplyCrossXCloseSo7UIImageCvau")
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

    func testShouldDetermineWhenAModuleStableSwiftFrameworkIsIncompatible() {
        guard let frameworkURL = Bundle(for: type(of: self)).url(forResource: "ModuleStableBuiltWithSwift5.1.2.framework", withExtension: nil) else {
            XCTFail("Could not load ModuleStableBuiltWithSwift5.1.2.framework from resources")
            return
        }

        guard let localSwiftVersion = SwiftToolchain.swiftVersion(from: "Apple Swift version 5.0 (swiftlang-1001.0.69.5 clang-1001.0.46.3)") else {
            XCTFail("Could not parse local swift version")
            return
        }

        guard let frameworkVersion = Frameworks.frameworkSwiftVersion(frameworkURL).single()?.value else {
            XCTFail("Could not get framework swift version")
            return
        }

        let result = Frameworks.checkSwiftFrameworkCompatibility(frameworkURL, swiftVersion: localSwiftVersion).single()

        XCTAssertNil(result?.value)
        XCTAssertEqual(result?.error, .incompatibleFrameworkSwiftVersions(local: localSwiftVersion, framework: frameworkVersion))
    }

    func testShouldDetermineWhenANonModuleStableSwiftFrameworkIsIncompatible() {
        guard let frameworkURL = Bundle(for: type(of: self)).url(forResource: "NonModuleStableBuiltWithSwift5.1.2.framework", withExtension: nil) else {
            XCTFail("Could not load NonModuleStableBuiltWithSwift5.1.2.framework from resources")
            return
        }

        guard let localSwiftVersion = SwiftToolchain.swiftVersion(from: "Apple Swift version 5.1 (swiftlang-1100.0.270.13 clang-1100.0.33.7)") else {
            XCTFail("Could not parse local swift version")
            return
        }

        guard let frameworkVersion = Frameworks.frameworkSwiftVersion(frameworkURL).single()?.value else {
            XCTFail("Could not get framework swift version")
            return
        }

        let result = Frameworks.checkSwiftFrameworkCompatibility(frameworkURL, swiftVersion: localSwiftVersion).single()

        XCTAssertNil(result?.value)
        XCTAssertEqual(result?.error, .incompatibleFrameworkSwiftVersions(local: localSwiftVersion, framework: frameworkVersion))
    }

    func testShouldDetermineWhenAModuleStableSwiftFrameworkIsCompatible() {
        guard let frameworkURL = Bundle(for: type(of: self)).url(forResource: "ModuleStableBuiltWithSwift5.1.2.framework", withExtension: nil) else {
            XCTFail("Could not load ModuleStableBuiltWithSwift5.1.2.framework from resources")
            return
        }

        guard let localSwiftVersion = SwiftToolchain.swiftVersion(from: "Apple Swift version 5.1 (swiftlang-1100.0.270.13 clang-1100.0.33.7)") else {
            XCTFail("Could not parse local swift version")
            return
        }

        guard let frameworkVersion = Frameworks.frameworkSwiftVersion(frameworkURL).single()?.value else {
            XCTFail("Could not get framework swift version")
            return
        }

        let result = Frameworks.checkSwiftFrameworkCompatibility(frameworkURL, swiftVersion: localSwiftVersion).single()

        XCTAssertEqual(result?.value, frameworkURL)
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
