@testable import CarthageKit
import Foundation
import Nimble
import XCTest

class ProxyTests: XCTestCase {
	func testShouldHaveNilDictionary() {
		let proxy = Proxy(environment: [:])
		expect(proxy.connectionProxyDictionary).to(beNil())
	}
	
	func testShouldHaveNilDictionary1() {
		let proxy = Proxy(environment: ["http_proxy": "http:\\github.com:8888"])
		expect(proxy.connectionProxyDictionary).to(beNil())
	}
	
	
	func testShouldSetTheHttpProperties() {
		let proxy = Proxy(environment: ["http_proxy": "http://github.com:8888", "HTTP_PROXY": "http://github.com:8888"])
		expect(proxy.connectionProxyDictionary).toNot(beNil())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPEnable] as? Bool).to(beTrue())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPProxy] as? String) == URL(string: "http://github.com:8888")?.host
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPPort] as? Int) == 8888
	}
	
	func testShouldNotSetTheHttpsProperties() {
		let proxy = Proxy(environment: ["http_proxy": "http://github.com:8888", "HTTP_PROXY": "http://github.com:8888"])
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSEnable]).to(beNil())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSProxy]).to(beNil())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSPort]).to(beNil())
	}
	
	
	func testShouldSetTheHttpsProperties() {
		let proxy = Proxy(environment: ["https_proxy": "https://github.com:8888", "HTTPS_PROXY": "https://github.com:8888"])
		expect(proxy.connectionProxyDictionary).toNot(beNil())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSEnable] as? Bool).to(beTrue())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSProxy] as? String) == URL(string: "https://github.com:8888")?.host
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSPort] as? Int) == 8888
	}
	
	func testShouldNotSetTheHttpProperties() {
		let proxy = Proxy(environment: ["https_proxy": "https://github.com:8888", "HTTPS_PROXY": "https://github.com:8888"])
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPEnable]).to(beNil())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPProxy]).to(beNil())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPPort]).to(beNil())
	}
	
	func testShouldSetTheHttpProperties1() {
		let proxy = Proxy(environment: [
			"http_proxy": "http://github.com:8888",
			"HTTP_PROXY": "http://github.com:8888",
			"https_proxy": "https://github.com:443",
			"HTTPS_PROXY": "https://github.com:443",
			])
		expect(proxy.connectionProxyDictionary).toNot(beNil())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPEnable] as? Bool).to(beTrue())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPProxy] as? String) == URL(string: "http://github.com:8888")?.host
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPPort] as? Int) == 8888
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSEnable] as? Bool).to(beTrue())
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSProxy] as? String) == URL(string: "https://github.com:443")?.host
		expect(proxy.connectionProxyDictionary?[kCFNetworkProxiesHTTPSPort] as? Int) == 443
	}
}
