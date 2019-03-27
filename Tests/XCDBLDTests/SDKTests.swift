import Foundation
import Nimble
import XCTest

@testable import XCDBLD

class SDKTests: XCTestCase {
    func testShouldReturnNilForEmptyString() {
        expect(SDK(rawValue: "")).to(beNil())
    }

    func testShouldReturnNilForUnexpectedInput() {
        expect(SDK(rawValue: "speakerOS")).to(beNil())
    }

    func testShouldReturnAValidValueForExpectedInput() {
        let watchOS = SDK(rawValue: "watchOS")
        expect(watchOS).notTo(beNil())
        expect(watchOS) == SDK.watchOS

        let watchOSSimulator = SDK(rawValue: "wAtchsiMulator")
        expect(watchOSSimulator).notTo(beNil())
        expect(watchOSSimulator) == SDK.watchSimulator

        let tvOS1 = SDK(rawValue: "tvOS")
        expect(tvOS1).notTo(beNil())
        expect(tvOS1) == SDK.tvOS

        let tvOS2 = SDK(rawValue: "appletvos")
        expect(tvOS2).notTo(beNil())
        expect(tvOS2) == SDK.tvOS

        let tvOSSimulator = SDK(rawValue: "appletvsimulator")
        expect(tvOSSimulator).notTo(beNil())
        expect(tvOSSimulator) == SDK.tvSimulator

        let macOS = SDK(rawValue: "macosx")
        expect(macOS).notTo(beNil())
        expect(macOS) == SDK.macOSX

        let iOS = SDK(rawValue: "iphoneos")
        expect(iOS).notTo(beNil())
        expect(iOS) == SDK.iPhoneOS

        let iOSimulator = SDK(rawValue: "iphonesimulator")
        expect(iOSimulator).notTo(beNil())
        expect(iOSimulator) == SDK.iPhoneSimulator
    }
}
