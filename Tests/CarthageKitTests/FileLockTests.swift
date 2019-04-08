//
//  FileLockTests.swift
//  CarthageKitTests
//
//  Created by Werner Altewischer on 06/04/2019.
//

import XCTest
@testable import CarthageKit

class FileLockTests: XCTestCase {
    
    var fileLock: FileLock!

    override func setUp() {
        continueAfterFailure = false
        
        // Put setup code here. This method is called before the invocation of each test method in the class.
        let temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let temporaryFilename = UUID().description.appending(".lock")
        let lockFileURL = temporaryDirectoryURL.appendingPathComponent(temporaryFilename)
        
        try? FileManager.default.removeItem(atPath: lockFileURL.path)
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFileURL.path))
        
        fileLock = FileLock(lockFileURL: lockFileURL)
    }

    override func tearDown() {
        let lockFileURL = fileLock.lockFileURL
        fileLock = nil
        
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFileURL.path))
    }

    func testLockUnlock() {
        
        XCTAssertFalse(fileLock.isLocked)
        
        XCTAssertTrue(fileLock.lock())
        
        XCTAssertTrue(fileLock.isLocked)
        
        XCTAssertFalse(fileLock.lock())
        XCTAssertTrue(fileLock.unlock())
        
        XCTAssertFalse(fileLock.isLocked)
        
        XCTAssertFalse(fileLock.unlock())
        
        XCTAssertTrue(fileLock.lock())
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileLock.lockFileURL.path))
        
        // Lock should be automatically removed afterwards, which is tested in tearDown
    }
    
    func testLockTimeout() {
        var start = Date()
        XCTAssertTrue(fileLock.lock(timeout: 1.0))
        
        // Test that no timeout occured
        XCTAssertTrue(Date().timeIntervalSince(start) < 0.5)
        
        XCTAssertTrue(fileLock.isLocked)
        
        start = Date()
        
        XCTAssertFalse(fileLock.lock(timeout: 1.0))
        
        XCTAssertTrue(Date().timeIntervalSince(start) >= 1.0)
        
        XCTAssertTrue(fileLock.isLocked)
    }
}
