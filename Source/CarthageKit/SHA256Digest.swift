import Foundation
import CommonCrypto
import Result

final class SHA256Digest {

    enum InputStreamError: Error {
        case createFailed(URL)
        case readFailed
    }

    private lazy var context: CC_SHA256_CTX = {
        var shaContext = CC_SHA256_CTX()
        CC_SHA256_Init(&shaContext)
        return shaContext
    }()
    private var result: Data?

    init() {
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

    /**
     Calculates a digest for the file at the specified url.
    */
    static func digestForFileAtURL(_ frameworkFileURL: URL) -> Result<Data, CarthageError> {
        let digest = SHA256Digest()
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
    static func digestForDirectoryAtURL(_ directoryURL: URL) -> Result<Data, CarthageError> {
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
                files.append((relativePath, fileURL))
            }
        }

        if let error = enumerationError {
            return .failure(CarthageError.readFailed(error.url, error.error as NSError))
        }

        //Ensure the files are in the same order every time by sorting them
        files.sort(by: { (tuple1, tuple2) -> Bool in
            tuple1.0 < tuple2.0
        })

        let digest = SHA256Digest()
        for (_, fileURL) in files {
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

        return .success(digest.finalize())
    }
}
