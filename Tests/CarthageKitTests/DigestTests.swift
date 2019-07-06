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

    override func setUp() {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

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

    private func makeTempFile(data: Data) throws -> URL {
        let tempDir = NSTemporaryDirectory()
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        let url = URL(fileURLWithPath: tempFile)
        try data.write(to: url)
        return url
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
