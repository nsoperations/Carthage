import XCTest
import Result
@testable import CarthageKit

class CopyFrameworksTests: XCTestCase {
    
    var targetDir: URL!
    var frameworkURL: URL!

    override func setUp() {
        super.setUp()
        self.continueAfterFailure = false
        
        guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "CopyFrameworks", withExtension: nil) else {
            XCTFail("Could not load CopyFrameworks fixture from resources")
            return
        }
        
        frameworkURL = directoryURL.appendingPathComponent("Reachability.framework")
        
        guard frameworkURL.isExistingDirectory else {
            XCTFail("Could not locate Reachability.framework")
            return
        }
        
        targetDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("CopyFrameworksTests")
        
        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            XCTFail("Could not create temporary directory: \(error)")
            return
        }
        
        self.continueAfterFailure = true
    }

    override func tearDown() {
        super.tearDown()
        if let tempDir = self.targetDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testCopySingleFramework() throws {
        
        let frameworksFolder = targetDir.appendingPathComponent("Frameworks")
        let symbolsFolder = targetDir.appendingPathComponent("Symbols")
        
        guard let result = CopyFramework.copyFramework(frameworkURL: frameworkURL, frameworksFolder: frameworksFolder, symbolsFolder: symbolsFolder, validArchitectures: ["x86_64"], codeSigningIdentity: nil, shouldStripDebugSymbols: true, shouldCopyBCSymbolMap: true).collect().single() else {
            XCTFail("No result received")
            return
        }
        
        guard case let Result.success(events) = result, !events.isEmpty else {
            XCTFail("No events received")
            return
        }
        
        XCTAssertTrue(frameworksFolder.isExistingDirectory)
        XCTAssertTrue(symbolsFolder.isExistingDirectory)
        
        XCTAssertTrue(frameworksFolder.appendingPathComponent("Reachability.framework").isExistingDirectory)
        XCTAssertTrue(symbolsFolder.appendingPathComponent("F34B9A4F-6143-3B8E-A845-C3CBAEB42E9B.bcsymbolmap").isExistingFile)
        XCTAssertTrue(symbolsFolder.appendingPathComponent("E766E8F0-8D9C-384C-8894-0A344C80D26C.bcsymbolmap").isExistingFile)
        XCTAssertTrue(symbolsFolder.appendingPathComponent("Reachability.framework.dSYM").isExistingDirectory)
    }
}
