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

     It will consider every regular non-hidden file for the digest, which is not git ignored, first sorting the relative paths alphabetically.
     */
    class func digestForDirectoryAtURL(_ directoryURL: URL, version: String = "", parentGitIgnore: GitIgnore? = nil) -> Result<Data, CarthageError> {
        do {
            
            #if DEBUG
            let lastPathComponent = directoryURL.lastPathComponent
            let timeStamp = Int64(Date().timeIntervalSince1970)
            _ = try? FileManager.default.createDirectory(atPath: "/tmp/carthage", withIntermediateDirectories: true, attributes: nil)
            let logFileURL = URL(fileURLWithPath: "/tmp/carthage/\(lastPathComponent)-\(version)-\(timeStamp)-digest.log")
            print("Writing digest log to: \(logFileURL.path)")
            var output = try FileOutputStream(fileURL: logFileURL)
            print("Calculating digest for directory: \(directoryURL.path)", to: &output)
            #endif
            
            let digest = self.init()
            try crawl(directoryURL, relativePath: nil, parentGitIgnore: parentGitIgnore) { fileURL, relativePath in

                guard let inputStream = InputStream(url: fileURL) else {
                    throw CarthageError.readFailed(fileURL, nil)
                }
                
                #if DEBUG
                let fileDigest = type(of: digest).digestForFileAtURL(fileURL)
                
                print("\(relativePath): \(fileDigest.value?.hexString ?? fileDigest.error!.description)", to: &output)
                #endif
                
                //calculate hash
                do {
                    try digest.update(inputStream: inputStream)
                } catch {
                    throw CarthageError.readFailed(fileURL, error as NSError?)
                }
            }
            let result = digest.finalize()
            
            #if DEBUG
            print("Final computed digest: \(result)", to: &output)
            #endif
            return .success(result)
        } catch let error as CarthageError {
            return .failure(error)
        } catch {
            return .failure(CarthageError.internalError(description: error.localizedDescription))
        }
    }

    private class func crawl(_ directoryURL: URL, relativePath: String?, parentGitIgnore: GitIgnore?, update: (URL, String) throws -> ()) throws {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]

        var urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles])
        } catch {
            throw CarthageError.readFailed(directoryURL, error as NSError?)
        }

        urls.sort { url1, url2 -> Bool in
            url1.lastPathComponent < url2.lastPathComponent
        }

        let gitIgnoreURL = directoryURL.appendingPathComponent(".gitignore")
        let gitIgnore: GitIgnore?

        if gitIgnoreURL.isExistingFile {
            gitIgnore = GitIgnore(parent: parentGitIgnore)
            do {
                try gitIgnore?.addPatterns(from: gitIgnoreURL)
            } catch {
                throw CarthageError.readFailed(gitIgnoreURL, error as NSError?)
            }
        } else {
            gitIgnore = parentGitIgnore
        }

        for url in urls {
            let resourceValues: URLResourceValues
            do {
                resourceValues = try url.resourceValues(forKeys: resourceKeys)
            } catch {
                throw CarthageError.readFailed(url, error as NSError?)
            }

            let subRelativePath = relativePath?.appendingPathComponent(url.lastPathComponent) ?? url.lastPathComponent
            let isDirectory = resourceValues.isDirectory ?? false
            let isIgnored = gitIgnore?.matches(relativePath: subRelativePath, isDirectory: isDirectory) ?? false

            guard !isIgnored else {
                continue
            }

            if isDirectory {
                // Directory
                try crawl(url, relativePath: subRelativePath, parentGitIgnore: gitIgnore, update: update)
            } else if (resourceValues.isRegularFile ?? false) {
                try update(url, subRelativePath)
            }
        }
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
