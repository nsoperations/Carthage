import XCTest
@testable import CarthageKit

class CopyFrameworksTests: XCTestCase {

    override func setUp() {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    /*
 copyFramework(frameworkURL: URL, frameworksFolder: URL, symbolsFolder: URL, validArchitectures: [String], codeSigningIdentity: String?, shouldStripDebugSymbols: Bool, shouldCopyBCSymbolMap: Bool, lockTimeout: Int? = nil, waitHandler: ((URL) -> Void)? = nil) -> SignalProducer<FrameworkEvent, CarthageError>
 */

    func testCopyFrameworks() {
        guard let testCartfileURL = Bundle(for: ResolverTests.self).url(forResource: "CopyFrameworks/ConflictingNames/Cartfile", withExtension: "") else {
            fail("Could not load Resolver/ConflictingNames/Cartfile from resources")
            return
        }
        let projectDirectoryURL = testCartfileURL.deletingLastPathComponent()
        let repositoryURL = projectDirectoryURL.appendingPathComponent("Repository")


        CopyFramework.copyFramework(frameworkURL: <#T##URL#>, frameworksFolder: <#T##URL#>, symbolsFolder: <#T##URL#>, validArchitectures: <#T##[String]#>, codeSigningIdentity: <#T##String?#>, shouldStripDebugSymbols: <#T##Bool#>, shouldCopyBCSymbolMap: <#T##Bool#>)
    }
}
