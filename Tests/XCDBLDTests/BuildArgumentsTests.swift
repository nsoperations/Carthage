import Foundation
import XCTest
import Nimble
import XCDBLD

class BuildArgumentsTests: XCTestCase {
    func testBuildArguments(arguments: [String], configure: ((inout BuildArguments) -> Void)? = nil) {
        let workspace = ProjectLocator.workspace(URL(string: "file:///Foo/Bar/workspace.xcworkspace")!)
        let project = ProjectLocator.projectFile(URL(string: "file:///Foo/Bar/project.xcodeproj")!)

        let codeSignArguments = [
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
            "CARTHAGE=YES",
            ]

        var subject = BuildArguments(project: workspace)
        configure?(&subject)

        expect(subject.arguments) == [
            "xcodebuild",
            "-workspace",
            "/Foo/Bar/workspace.xcworkspace",
            ] + arguments + codeSignArguments

        subject = BuildArguments(project: project)
        configure?(&subject)

        expect(subject.arguments) == [
            "xcodebuild",
            "-project",
            "/Foo/Bar/project.xcodeproj",
            ] + arguments + codeSignArguments
    }

    func testHasADefaultSetOfArguments() {
        testBuildArguments(arguments: [])
    }

    func testIncludesTheSchemeIfOneIsGiven() {
        testBuildArguments(arguments: ["-scheme", "exampleScheme"]) { subject in
            subject.scheme = Scheme("exampleScheme")
        }
    }

    func testIncludesTheConfigurationIfOneIfGiven() {
        testBuildArguments(arguments: ["-configuration", "exampleConfiguration"]) { subject in
            subject.configuration = "exampleConfiguration"
        }
    }

    func testIncludesTheDerivedDataPath() {
        testBuildArguments(arguments: ["-derivedDataPath", "/path/to/derivedDataPath"]) { subject in
            subject.derivedDataPath = "/path/to/derivedDataPath"
        }
    }

    func testIncludesEmptyDerivedDataPath() {
        testBuildArguments(arguments: []) { subject in
            subject.derivedDataPath = ""
        }
    }

    func testIncludesTheToolchain() {
        testBuildArguments(arguments: ["-toolchain", "org.swift.3020160509a"]) { subject in
            subject.toolchain = "org.swift.3020160509a"
        }
    }

    func testDoesNotIncludeTheSDKFlagIfMacOSXIsSpecified() {
        for sdk in SDK.allSDKs.subtracting([.macOSX]) {
            testBuildArguments(arguments: ["-sdk", sdk.rawValue]) { subject in
                subject.sdk = sdk
            }
        }

        // Passing in -sdk macosx appears to break implicit dependency
        // resolution (see Carthage/Carthage#347).
        //
        // Since we wouldn't be trying to build this target unless it were
        // for macOS already, just let xcodebuild figure out the SDK on its
        // own.
        testBuildArguments(arguments: []) { subject in
            subject.sdk = .macOSX
        }
    }

    func testIncludesTheDestinationIfGiven() {
        testBuildArguments(arguments: ["-destination", "exampleDestination"]) { subject in
            subject.destination = "exampleDestination"
        }
    }

    func testIncludesOnlyActiveArchYesIfItsSetToTrue() {
        testBuildArguments(arguments: ["ONLY_ACTIVE_ARCH=YES"]) { subject in
            subject.onlyActiveArchitecture = true
        }
    }

    func testIncludesOnlyActiveArchNoIfItsSetToFalse() {
        testBuildArguments(arguments: ["ONLY_ACTIVE_ARCH=NO"]) { subject in
            subject.onlyActiveArchitecture = false
        }
    }
}
