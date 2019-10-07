//
//  DigestTests.swift
//  CarthageKitTests
//
//  Created by Werner Altewischer on 05/07/2019.
//

import XCTest
import ReactiveTask
@testable import CarthageKit

class DigestTests: XCTestCase {

    func testSHADigestFromFile() throws {
        let data = Data.makeRandom(length: 100 * 1024)
        let fileURL = try makeTempFile(data: data)

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        do {
            let digest = SHA256Digest()

            try digest.update(url: fileURL)
            let result = digest.finalize().hexString

            let expected = try referenceSHA256Sum(data: data)

            XCTAssertEqual(expected, result)
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }
    }

    func testSHADigestFromData() throws {
        let data = Data.makeRandom(length: 4096)

        let digest = SHA256Digest()
        digest.update(data: data)
        let result = digest.finalize().hexString

        let expected = try referenceSHA256Sum(data: data)

        XCTAssertEqual(expected, result)

        //Should be ignored, already finalized
        digest.update(data: data)

        //Should yield the same result
        let result1 = digest.finalize().hexString

        XCTAssertEqual(expected, result1)
    }

    func testSHADigestFromDirectory() throws {

        var randomData = [Data]()
        for _ in 0..<10 {
            randomData.append(Data.makeRandom(length: 4096))
        }

        let tempDir = try makeTempDirectory()
        defer {
            tempDir.removeIgnoringErrors()
        }

        for data in randomData {
            let filename = data.prefix(16).hexString
            let fileURL = tempDir.appendingPathComponent(filename)
            try data.write(to: fileURL)
        }

        randomData.sort {
            $0.hexString < $1.hexString
        }

        let digest = SHA256Digest()
        for data in randomData {
            digest.update(data: data)
        }
        let expectedHash = digest.finalize().hexString
        let actualHash = try SHA256Digest.digestForDirectoryAtURL(tempDir).map { $0.hexString }.get()

        XCTAssertEqual(expectedHash, actualHash)

        // Add files which should be ignored by default

        let gitIgnore = GitIgnore()

        gitIgnore.addPattern("*.tmp")
        gitIgnore.addPattern("*.swp")

        try Data.makeRandom(length: 256).write(to: tempDir.appendingPathComponent("\(UUID()).tmp"))
        try Data.makeRandom(length: 256).write(to: tempDir.appendingPathComponent("\(UUID()).swp"))

        let actualHash2 = try SHA256Digest.digestForDirectoryAtURL(tempDir, parentGitIgnore: gitIgnore).map { $0.hexString }.get()

        XCTAssertEqual(expectedHash, actualHash2)

        let actualHash3 = try SHA256Digest.digestForDirectoryAtURL(tempDir, parentGitIgnore: nil).map { $0.hexString }.get()

        XCTAssertNotEqual(expectedHash, actualHash3)
    }

    private func makeTempDirectory() throws -> URL {
        let tempDir = NSTemporaryDirectory()
        let subDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true, attributes: nil)
        return URL(fileURLWithPath: subDir)
    }

    private func makeTempFile(data: Data, in directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) throws -> URL {
        let tempFileURL = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tempFileURL)
        return tempFileURL
    }

    private func referenceSHA256Sum(data: Data) throws -> String {
        let tempURL = try makeTempFile(data: data)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let task = Task("/usr/bin/shasum", arguments: ["-a", "256", tempURL.path])

        let result = task.getStdOutString()

        return try String(result.get().prefix(64))
    }

}

extension Data {
    // Create random data with the specified length in bytes
    static func makeRandom(length: Int) -> Data {
        var result = Data(capacity: length)
        for _ in 0..<length {
            guard let byte = UInt8(exactly: arc4random_uniform(UInt32(UInt8.max) + 1)) else {
                preconditionFailure("Expected the random byte to hava value in the range [0, UInt8.max]")
            }
            result.append(byte)
        }
        return result
    }
}
