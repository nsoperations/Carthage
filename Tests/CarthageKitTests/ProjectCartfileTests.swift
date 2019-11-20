import CarthageKit
import Foundation
import Result
import XCTest
import XCDBLD

class CartfileProjectTests: XCTestCase {
    func testShouldParseProjectCartfile() {
        guard let testCartfileURL = Bundle(for: type(of: self)).url(forResource: "TestCartfile", withExtension: "project") else {
            XCTFail("Could not find TestCartFile.project in resources")
            return
        }
        guard let testCartfileString = try? String(contentsOf: testCartfileURL, encoding: .utf8) else {
            XCTFail("Could not load Cartfile as string, is it UTF8 encoded?")
            return
        }
        
        let result = ProjectCartfile.from(string: testCartfileString)
        XCTAssertNil(result.error)
        
        guard let cartfile = result.value else {
            XCTFail("Cartfile could not be be parsed")
            return
        }
        
        guard let scheme1 = cartfile.schemeConfigurations["SomeiOSScheme"] else {
            XCTFail("Expected SomeiOSScheme to be present")
            return
        }
        
        XCTAssertEqual("SomeWorkspace.xcworkspace", scheme1.project)
        XCTAssertEqual([SDK.iPhoneOS, SDK.iPhoneSimulator], scheme1.sdks)
        
        let baseURL = URL(fileURLWithPath: "/tmp")
        
        XCTAssertEqual(ProjectLocator.workspace(baseURL.appendingPathComponent("SomeWorkspace.xcworkspace")), scheme1.projectLocator(in: baseURL))
        
        guard let scheme2 = cartfile.schemeConfigurations["SomeWatchScheme"] else {
            XCTFail("Expected SomeWatchScheme to be present")
            return
        }
        
        XCTAssertEqual("SomeProject.xcodeproj", scheme2.project)
        XCTAssertEqual([SDK.watchOS, SDK.watchSimulator], scheme2.sdks)
        
        XCTAssertEqual(ProjectLocator.projectFile(baseURL.appendingPathComponent("SomeProject.xcodeproj")), scheme2.projectLocator(in: baseURL))
    }
    
    func testShouldParseEmptyProjectCartfile() {
        switch ProjectCartfile.from(string: "") {
        case let .failure(error):
            XCTFail("Unexpected error occured: \(error)")
        case let .success(projectCartfile):
            XCTAssertTrue(projectCartfile.schemeConfigurations.isEmpty)
        }
        
        switch ProjectCartfile.from(string: "{}") {
        case let .failure(error):
            XCTFail("Unexpected error occured: \(error)")
        case let .success(projectCartfile):
            XCTAssertTrue(projectCartfile.schemeConfigurations.isEmpty)
        }
    }
}

