import Foundation
import XCTest
@testable import CarthageKit

class DebugSymbolsMapperTests: XCTestCase {

    var fixtureBaseURL: URL!

    override func setUp() {
        self.continueAfterFailure = false
        guard let nonNilURL = Bundle(for: type(of: self)).url(forResource: "HelloWorld", withExtension: nil) else {
            XCTFail("Expected HelloWorld to be loadable from resources")
            return
        }
        fixtureBaseURL = nonNilURL
    }

    func testMapSymbols() {

        let frameworkURL = fixtureBaseURL.appendingPathComponents(["Carthage", "Build", "iOS", "HelloWorld.framework"])
        let dsymURL = fixtureBaseURL.appendingPathComponents(["Carthage", "Build", "iOS", "HelloWorld.framework.dSYM"])
        let sourceURL = fixtureBaseURL.appendingPathComponent("HelloWorld")
        let result = DebugSymbolsMapper.mapSymbolLocations(frameworkURL: frameworkURL, dsymURL: dsymURL, sourceURL: sourceURL)

        guard case .success = result else {
            XCTFail("Expected successful result, but got: \(result)")
            return
        }

        let resourcesURL = dsymURL.appendingPathComponents(["Contents", "Resources"])

        do {
            let plistFiles = try FileManager.default.contentsOfDirectory(at: resourcesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).filter { $0.pathExtension == "plist" }

            for plistFile in plistFiles {
                let data = try Data(contentsOf: plistFile)
                guard let dict = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] else {
                    XCTFail("Unexpected property list format, expected a dictionary")
                    continue
                }
                XCTAssertNotNil(dict["DBGArchitecture"])
                XCTAssertNotNil(dict["DBGBuildSourcePath"])

                guard let value1 = dict["DBGSourcePath"], let sourcePath = value1 as? String else {
                    XCTFail("Expected DBGSourcePath to be defined")
                    continue
                }
                XCTAssertTrue(URL(fileURLWithPath: sourcePath).isExistingDirectory)

                guard let value2 = dict["DBGDSYMPath"], let dsymPath = value2 as? String else {
                    XCTFail("Expected DBGDSYMPath to be defined")
                    continue
                }
                XCTAssertTrue(URL(fileURLWithPath: dsymPath).isExistingFile)

                guard let value3 = dict["DBGSymbolRichExecutable"], let binaryPath = value3 as? String else {
                    XCTFail("Expected DBGSymbolRichExecutable to be defined")
                    continue
                }
                XCTAssertTrue(URL(fileURLWithPath: binaryPath).isExistingFile)
            }
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }
    }

}
