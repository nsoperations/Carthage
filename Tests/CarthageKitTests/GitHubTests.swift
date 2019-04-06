import Foundation
import Nimble
import XCTest

import Tentacle
@testable import CarthageKit

class GitHubTests: XCTestCase {
    
    var insideGitHubRedirectURL: URL!
    var outsideGitHubRedirectURL: URL!
    var task: URLSessionDataTask!
    var authToken: String!
    var session: URLSession!
    var requestURL: URL!
    var request: URLRequest!
    
    override func setUp() {
        session = URLSession(configuration: .default)
        requestURL = URL(string: "https://api.github.com/some_api_endpoint")!
        insideGitHubRedirectURL = URL(string: "https://api.github.com/some_redirected_api_endpoint")!
        outsideGitHubRedirectURL = URL(string: "https://api.notgithub.com/")!
        
        request = URLRequest(url: requestURL)
        authToken = "TOKEN"
        request.setValue(authToken, forHTTPHeaderField: "Authorization")
        
        task = session.dataTask(with: request)
        
    }
    
    func redirectURLResponse(location: URL) -> HTTPURLResponse {
        return HTTPURLResponse(url: requestURL, statusCode: 302, httpVersion: "1.1", headerFields: [
            "Location": location.absoluteString
            ])!
    }
    
    func testShouldParseOwnerNameForm() {
        let identifier = "ReactiveCocoa/ReactiveSwift"
        let result = Repository.fromIdentifier(identifier)
        expect(result.value?.0) == Server.dotCom
        expect(result.value?.1) == Repository(owner: "ReactiveCocoa", name: "ReactiveSwift")
        expect(result.error).to(beNil())
    }
    
    func testShouldRejectGitProtocol() {
        let identifier = "git://git@some_host/some_owner/some_repo.git"
        let expected = ScannableError(message: "invalid GitHub repository identifier \"\(identifier)\"")
        let result = Repository.fromIdentifier(identifier)
        expect(result.value).to(beNil())
        expect(result.error) == expected
    }
    
    func testShouldRejectSshProtocol() {
        let identifier = "ssh://git@some_host/some_owner/some_repo.git"
        let expected = ScannableError(message: "invalid GitHub repository identifier \"\(identifier)\"")
        let result = Repository.fromIdentifier(identifier)
        expect(result.value).to(beNil())
        expect(result.error) == expected
    }
}
