import XCTest
import Result
import ReactiveTask
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
            try? FileManager.default.removeItem(at: targetDir)
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

    func copySingleFramework(includeSymbols: Bool, strip: Bool, validArchs: [String], assertions: (URL, URL, URL, URL) -> Void) throws {
        
        let frameworksFolder = targetDir.appendingPathComponent("Frameworks")
        let symbolsFolder = targetDir.appendingPathComponent("Symbols")
        
        guard let result = CopyFramework.copyFramework(frameworkURL: frameworkURL, frameworksFolder: frameworksFolder, symbolsFolder: symbolsFolder, validArchitectures: validArchs, codeSigningIdentity: nil, shouldStripDebugSymbols: strip, shouldCopyBCSymbolMap: includeSymbols).collect().single() else {
            XCTFail("No result received")
            return
        }
        
        guard case let Result.success(events) = result, !events.isEmpty else {
            XCTFail("No events received")
            return
        }
        
        XCTAssertTrue(frameworksFolder.isExistingDirectory)
        XCTAssertTrue(symbolsFolder.isExistingDirectory)
        
        let frameworkURL = frameworksFolder.appendingPathComponent("Reachability.framework")
        let symbol1URL = symbolsFolder.appendingPathComponent("F34B9A4F-6143-3B8E-A845-C3CBAEB42E9B.bcsymbolmap")
        let symbol2URL = symbolsFolder.appendingPathComponent("E766E8F0-8D9C-384C-8894-0A344C80D26C.bcsymbolmap")
        let dsymURL = symbolsFolder.appendingPathComponent("Reachability.framework.dSYM")
        let binaryURL = frameworkURL.appendingPathComponent("Reachability")
        
        let frameworkArchitectures = try Frameworks.architecturesInPackage(frameworkURL).collect().single()?.get() ?? []
        let dsymArchitectures = try Frameworks.architecturesInPackage(dsymURL).collect().single()?.get() ?? []
        
        XCTAssertEqual(frameworkArchitectures.sorted(), validArchs.sorted())
        XCTAssertEqual(dsymArchitectures.sorted(), validArchs.sorted())
        
        XCTAssertTrue(binaryURL.isExistingFile)
        
        XCTAssertFalse(frameworkURL.appendingPathComponent("PrivateHeaders").isExistingFileOrDirectory)
        XCTAssertFalse(frameworkURL.appendingPathComponent("Modules").isExistingFileOrDirectory)
        XCTAssertFalse(frameworkURL.appendingPathComponent("Headers").isExistingFileOrDirectory)
        XCTAssertEqual(!strip, hasSymbols(binaryURL))
        
        assertions(frameworkURL, dsymURL, symbol1URL, symbol2URL)
    }
    
    func testCopySingleFrameworkIncludingSymbols() throws {
        
        try copySingleFramework(includeSymbols: true, strip: true, validArchs: ["x86_64"]) { (frameworkURL, dsymURL, symbol1URL, symbol2URL) in
            XCTAssertTrue(frameworkURL.isExistingDirectory)
            XCTAssertTrue(symbol1URL.isExistingFile)
            XCTAssertTrue(symbol2URL.isExistingFile)
            XCTAssertTrue(dsymURL.isExistingDirectory)
        }
    }
    
    func testCopySingleFrameworkExcludingSymbols() throws {
        
        try copySingleFramework(includeSymbols: false, strip: true, validArchs: ["x86_64"]) { (frameworkURL, dsymURL, symbol1URL, symbol2URL) in
            XCTAssertTrue(frameworkURL.isExistingDirectory)
            XCTAssertFalse(symbol1URL.isExistingFile)
            XCTAssertFalse(symbol2URL.isExistingFile)
            XCTAssertTrue(dsymURL.isExistingDirectory)
        }
    }
    
    func testCopySingleFrameworkMultipleArchs() throws {
        
        try copySingleFramework(includeSymbols: true, strip: false, validArchs: ["x86_64", "armv7"]) { (frameworkURL, dsymURL, symbol1URL, symbol2URL) in
            XCTAssertTrue(frameworkURL.isExistingDirectory)
            XCTAssertTrue(symbol1URL.isExistingFile)
            XCTAssertTrue(symbol2URL.isExistingFile)
            XCTAssertTrue(dsymURL.isExistingDirectory)
        }
    }
    
    private func hasSymbols(_ url: URL) -> Bool {
        let task = Task(launchCommand: "/usr/bin/xcrun dsymutil --dump-debug-map \(url.path) | grep -c symbols")
        
        let result = task.getStdOutString().flatMapError { (error) -> Result<String, Error> in
            Result.success("0")
        }
        return (try? result.get()) != "0"
    }
}
