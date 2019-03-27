@testable import CarthageKit
import Foundation
import Nimble
import XCTest
import ReactiveSwift
import Result

class MachHeaderTests: XCTestCase {
	
	func testShouldListAllMachHeadersForAGivenMachOFile() {
		guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "Alamofire.framework", withExtension: nil) else {
			fail("Could not load Alamofire.framework from resources")
			return
		}
		
		let result = CarthageKit
			.MachHeader
			.headers(forMachOFileAtUrl: directoryURL.appendingPathComponent("Alamofire"))
			.collect()
			.single()
		
		expect(result?.value?.count) == 36
	}
}
