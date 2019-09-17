//
//  FrameworksTests.swift
//  CarthageKitTests
//
//  Created by Werner Altewischer on 05/09/2019.
//

import XCTest
@testable import CarthageKit

public class FrameworksTests: XCTestCase {
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
                XCTAssertEqual("5.1+1100.0.270.6", localVersion.commitish)
                XCTAssertEqual("5.1+1100.0.266.1", frameworkVersion.commitish)
            default:
                XCTFail("Expected incompatibleFrameworkSwiftVersions error, but got: \(error)")
            }
        default:
            XCTFail("Expected failure: the framework should not be compatible")
        }
    }
}
