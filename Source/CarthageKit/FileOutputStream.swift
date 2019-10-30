import Foundation

class FileOutputStream: TextOutputStream {
    private let fileHandle: FileHandle
    private let encoding: String.Encoding
    
    convenience init(fileURL: URL, encoding: String.Encoding = .utf8) throws {
        
        let mode = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        let fileDescriptor = open(fileURL.path, O_CREAT | O_WRONLY | O_TRUNC, mode)
        
        if fileDescriptor < 0 {
            let posixErrorCode = POSIXErrorCode(rawValue: errno)!
            throw POSIXError(posixErrorCode)
        }
        
        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        self.init(fileHandle: fileHandle, encoding: encoding)
    }
    
    init(fileHandle: FileHandle, encoding: String.Encoding = .utf8) {
        self.fileHandle = fileHandle
        self.encoding = encoding
    }
    
    func write(_ string: String) {
        if let data = string.data(using: encoding) {
            fileHandle.write(data)
        }
    }
}
