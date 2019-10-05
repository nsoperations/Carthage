import Foundation
import CommonCrypto
import Result

class Digest {
    enum InputStreamError: Error {
        case createFailed(URL)
        case readFailed
    }
    
    private var result: Data?
    
    required init() {
    }
    
    func update(url: URL) throws {
        guard let inputStream = InputStream(url: url) else {
            throw InputStreamError.createFailed(url)
        }
        return try update(inputStream: inputStream)
    }
    
    func update(inputStream: InputStream) throws {
        guard result == nil else {
            return
        }
        inputStream.open()
        defer {
            inputStream.close()
        }
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }
        while inputStream.hasBytesAvailable {
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
        updateImpl(bytes: bytes, length: length)
    }
    
    fileprivate func updateImpl(bytes: UnsafeRawPointer, length: Int) {
        fatalError("Should be implemented")
    }
    
    fileprivate func finalizeImpl() -> Data {
        fatalError("Should be implemented")
    }
    
    func finalize() -> Data {
        if let calculatedResult = result {
            return calculatedResult
        }
        let theResult = self.finalizeImpl()
        result = theResult
        return theResult
    }
    
    /**
     Calculates a digest for the file at the specified url.
     */
    class func digestForFileAtURL(_ frameworkFileURL: URL) -> Result<Data, CarthageError> {
        let digest = self.init()
        do {
            try digest.update(url: frameworkFileURL)
        } catch {
            return .failure(CarthageError.readFailed(frameworkFileURL, error as NSError?))
        }
        return .success(digest.finalize())
    }
    
    /**
     Calculates a digest for the directory at the specified URL, recursing into sub directories.
     
     It will consider every regular non-hidden file for the digest, first sorting the relative paths alhpabetically.
     */
    class func digestForDirectoryAtURL(_ directoryURL: URL, shouldIgnore: ((String) -> Bool)? = nil) -> Result<Data, CarthageError> {
        
        print("Calculating digest for directory at URL: \(directoryURL)")
        
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        var enumerationError: (error: Error, url: URL)?
        
        let errorHandler: (URL, Error) -> Bool = { url, error -> Bool in
            enumerationError = (error, url)
            return false
        }
        
        let rootURL = directoryURL.resolvingSymlinksInPath()
        var rootPath = directoryURL.resolvingSymlinksInPath().path
        if !rootPath.hasSuffix("/") {
            rootPath += "/"
        }
        
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles], errorHandler: errorHandler) else {
            return .failure(CarthageError.readFailed(directoryURL, nil))
        }
        
        var files = [(String, URL)]()
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
            guard let regularFile = resourceValues?.isRegularFile else {
                return .failure(CarthageError.readFailed(fileURL, nil))
            }
            if regularFile {
                let filePath = fileURL.resolvingSymlinksInPath().path
                assert(filePath.hasPrefix(rootPath))
                let relativePath = String(filePath.substring(from: rootPath.count))
                if !(shouldIgnore?(relativePath) ?? false) {
                    files.append((relativePath, fileURL))
                }
            }
        }
        
        if let error = enumerationError {
            return .failure(CarthageError.readFailed(error.url, error.error as NSError))
        }
        
        //Ensure the files are in the same order every time by sorting them
        files.sort(by: { (tuple1, tuple2) -> Bool in
            tuple1.0 < tuple2.0
        })
        
        let digest = self.init()
        
        print("Digest instance: \(digest)")
        
        for (_, fileURL) in files {
            print("Including file: \(fileURL)")
            guard let inputStream = InputStream(url: fileURL) else {
                return .failure(CarthageError.readFailed(fileURL, nil))
            }
            //calculate hash
            do {
                try digest.update(inputStream: inputStream)
            } catch {
                return .failure(CarthageError.readFailed(fileURL, error as NSError?))
            }
        }
        
        let result = digest.finalize()
        
        print("Calculated result: \(result)")
        
        return .success(result)
    }
}

final class SHA256Digest: Digest {
    
    private lazy var context: CC_SHA256_CTX = {
        var shaContext = CC_SHA256_CTX()
        CC_SHA256_Init(&shaContext)
        return shaContext
    }()

    override fileprivate func updateImpl(bytes: UnsafeRawPointer, length: Int) {
        _ = CC_SHA256_Update(&self.context, bytes, CC_LONG(length))
    }
    
    override fileprivate func finalizeImpl() -> Data {
        var resultBuffer = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&resultBuffer, &self.context)
        return Data(bytes: resultBuffer)
    }
}

final class MD5Digest: Digest {
    
    private lazy var context: CC_MD5_CTX = {
        var shaContext = CC_MD5_CTX()
        CC_MD5_Init(&shaContext)
        return shaContext
    }()
    
    override fileprivate func updateImpl(bytes: UnsafeRawPointer, length: Int) {
        _ = CC_MD5_Update(&self.context, bytes, CC_LONG(length))
    }
    
    override fileprivate func finalizeImpl() -> Data {
        var resultBuffer = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        CC_MD5_Final(&resultBuffer, &self.context)
        return Data(bytes: resultBuffer)
    }
}
