@testable import CarthageKit
import Nimble
import XCTest

class CarfileCommentTests: XCTestCase {
	func testShouldNotAlterStringsWithNoComments() {
		[
			"foo bar\nbaz",
			"",
			"\n",
			"this is a \"value\"",
			"\"value\" this is",
			"\"unclosed",
			"unopened\"",
			"I say \"hello\" you say \"goodbye\"!"
			]
			.forEach {
				expect($0.strippingTrailingCartfileComment) == $0
		}
	}
	
	func testShouldNotAlterStringsWithCommentMarkerInQuotes() {
		[
			"foo bar \"#baz\"",
			"\"#quotes\" is the new \"quotes\"",
			"\"#\""
			]
			.forEach {
				expect($0.strippingTrailingCartfileComment) == $0
		}
	}
	
	func testShouldRemoveComments() {
		expect("#".strippingTrailingCartfileComment)
			== ""
		expect("\n  #\n".strippingTrailingCartfileComment)
			== "\n  "
		expect("I have some #comments!".strippingTrailingCartfileComment)
			== "I have some "
		expect("Some don't \"#matter\" and some # do!".strippingTrailingCartfileComment)
			== "Some don't \"#matter\" and some "
		expect("\"a\" b# # \"c\" #".strippingTrailingCartfileComment)
			== "\"a\" b"
	}
}
