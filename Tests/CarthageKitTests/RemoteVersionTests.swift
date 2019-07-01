import Foundation
import Nimble
import ReactiveSwift
import Tentacle
import XCTest

import struct Foundation.URL

@testable import CarthageKit

class RemoteVersionTests: XCTestCase {
	func testShouldReturnVersion() {
		guard let aboutURL = URL(string: "about:blank") else {
			fail("Expected aboutURL to not be nil")
			return
		}
		let release = Release(id: 0, tag: "0.1.0", url: aboutURL, assets: [])
		let producer = SignalProducer<Release, CarthageError>(value: release)
        XCTAssertEqual(producer.getLatestVersion(), SemanticVersion(0, 1, 0))
	}
	
	func testVersionTimeout() {
		let expectation = XCTestExpectation(description: "timeout")
		var version: SemanticVersion? = SemanticVersion(0, 0, 0)
		DispatchQueue.main.async {
			version = SignalProducer.never.getLatestVersion()
			XCTAssertNil(version)
			expectation.fulfill()
		}
		XCTAssertNotNil(version)
		wait(for: [expectation], timeout: 0.6)
	}
}
