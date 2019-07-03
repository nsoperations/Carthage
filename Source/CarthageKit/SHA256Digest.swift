import Foundation
import CommonCrypto

final class SHA256Digest {
    
    enum InputStreamError: Error {
        case readFailed
    }
    
    private lazy var context: CC_SHA256_CTX = {
        var shaContext = CC_SHA256_CTX()
        CC_SHA256_Init(&shaContext)
        return shaContext
    }()
    private var result: Data? = nil
    
    init() {
    }
    
    func update(inputStream: InputStream) throws {
        guard result == nil else {
            return
        }
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        while true {
            let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                //Stream error occured
                throw (inputStream.streamError ?? InputStreamError.readFailed)
            } else if bytesRead == 0 {
                //EOF
                break
            }
            self.update(bytes: buffer, length: bytesRead)
        }
        buffer.deallocate()
    }
    
    func update(data: Data) {
        guard result == nil else {
            return
        }
        data.withUnsafeBytes {
            self.update(bytes: $0, length: data.count)
        }
    }
    
    func update(bytes: UnsafeRawPointer, length: Int) {
        guard result == nil else {
            return
        }
        _ = CC_SHA256_Update(&self.context, bytes, CC_LONG(length))
    }
    
    func finalize() -> Data {
        if let calculatedResult = result {
            return calculatedResult
        }
        var resultBuffer = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&resultBuffer, &self.context)
        let theResult = Data(bytes: resultBuffer)
        result = theResult
        return theResult
    }
    
    static func sum(_ data: Data) -> Data {
        let digest = SHA256Digest()
        digest.update(data: data)
        return digest.finalize()
    }
}
