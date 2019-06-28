import Foundation
import ReactiveSwift
import Result

/// Generic file manipulation helper methods
final class Files {

    static let tempDirTemplate = "carthage.XXXXXX"

    /// Copies a product into the given folder. The folder will be created if it
    /// does not already exist, and any pre-existing version of the product in the
    /// destination folder will be deleted before the copy of the new version.
    ///
    /// If the `from` URL has the same path as the `to` URL, and there is a resource
    /// at the given path, no operation is needed and the returned signal will just
    /// send `.success`.
    ///
    /// Returns a signal that will send the URL after copying upon .success.
    static func copyFile(from: URL, to: URL) -> SignalProducer<URL, CarthageError> { // swiftlint:disable:this identifier_name
        return SignalProducer<URL, CarthageError> { () -> Result<URL, CarthageError> in
            let manager = FileManager.default

            // This signal deletes `to` before it copies `from` over it.
            // If `from` and `to` point to the same resource, there's no need to perform a copy at all
            // and deleting `to` will also result in deleting the original resource without copying it.
            // When `from` and `to` are the same, we can just return success immediately.
            //
            // See https://github.com/Carthage/Carthage/pull/1160
            if manager.fileExists(atPath: to.path) && from.absoluteURL == to.absoluteURL {
                return .success(to)
            }

            // Although some methods’ documentation say: “YES if createIntermediates
            // is set and the directory already exists)”, it seems to rarely
            // returns NO and NSFileWriteFileExistsError error. So we should
            // ignore that specific error.
            // See: https://developer.apple.com/documentation/foundation/filemanager/1415371-createdirectory
            func result(allowingErrorCode code: Int, _ result: Result<(), CarthageError>) -> Result<(), CarthageError> {
                if case .failure(.writeFailed(_, let error?)) = result, error.code == code {
                    return .success(())
                }
                return result
            }

            let createDirectory = { try manager.createDirectory(at: $0, withIntermediateDirectories: true) }
            return result(allowingErrorCode: NSFileWriteFileExistsError, Result(at: to.deletingLastPathComponent(), attempt: createDirectory))
                .flatMap { _ in
                    result(allowingErrorCode: NSFileNoSuchFileError, Result(at: to, attempt: manager.removeItem(at:)))
                }
                .flatMap { _ in
                    return Result(at: to, attempt: { destination /* to */ in
                        try manager.copyItem(at: from, to: destination, avoiding·rdar·32984063: true)
                        return destination
                    })
            }
        }
    }

    /// Moves the source file at the given URL to the specified destination URL
    ///
    /// Sends the final file URL upon .success.
    static func moveFile(from: URL, to: URL) -> SignalProducer<URL, CarthageError> { // swiftlint:disable:this identifier_name
        return SignalProducer<URL, CarthageError> { () -> Result<URL, CarthageError> in
            let manager = FileManager.default

            // This signal deletes `to` before it copies `from` over it.
            // If `from` and `to` point to the same resource, there's no need to perform a copy at all
            // and deleting `to` will also result in deleting the original resource without copying it.
            // When `from` and `to` are the same, we can just return success immediately.
            //
            // See https://github.com/Carthage/Carthage/pull/1160
            if manager.fileExists(atPath: to.path) && from.absoluteURL == to.absoluteURL {
                return .success(to)
            }

            // Although some methods’ documentation say: “YES if createIntermediates
            // is set and the directory already exists)”, it seems to rarely
            // returns NO and NSFileWriteFileExistsError error. So we should
            // ignore that specific error.
            // See: https://developer.apple.com/documentation/foundation/filemanager/1415371-createdirectory
            func result(allowingErrorCode code: Int, _ result: Result<(), CarthageError>) -> Result<(), CarthageError> {
                if case .failure(.writeFailed(_, let error?)) = result, error.code == code {
                    return .success(())
                }
                return result
            }

            let createDirectory = { try manager.createDirectory(at: $0, withIntermediateDirectories: true) }
            return result(allowingErrorCode: NSFileWriteFileExistsError, Result(at: to.deletingLastPathComponent(), attempt: createDirectory))
                .flatMap { _ in
                    result(allowingErrorCode: NSFileNoSuchFileError, Result(at: to, attempt: manager.removeItem(at:)))
                }
                .flatMap { _ in

                    // Tries `rename()` system call at first.
                    let result = from.withUnsafeFileSystemRepresentation { old in
                        to.withUnsafeFileSystemRepresentation { new in
                            rename(old!, new!)
                        }
                    }
                    if result == 0 {
                        return .success(to)
                    }

                    if errno != EXDEV {
                        return .failure(.taskError(.posixError(errno)))
                    }

                    // If the “Cross-device link” error occurred, then falls back to
                    // `FileManager.moveItem(at:to:)`.
                    //
                    // See https://github.com/Carthage/Carthage/issues/706 and
                    // https://github.com/Carthage/Carthage/issues/711.
                    return Result(at: to, attempt: { destination in
                        try FileManager.default.moveItem(at: from, to: destination)
                        return destination
                    })
            }
        }
    }

    /// Removes the file located at the given URL
    ///
    /// Sends empty value on successful removal
    static func removeItem(at url: URL) -> SignalProducer<(), CarthageError> {
        return SignalProducer {
            Result(at: url, attempt: FileManager.default.removeItem(at:))
        }
    }

}

extension SignalProducer where Value == URL, Error == CarthageError {
    /// Copies existing files sent from the producer into the given directory.
    ///
    /// Returns a producer that will send locations where the copied files are.
    func copyFileURLsIntoDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        return producer
            .filter { fileURL in (try? fileURL.checkResourceIsReachable()) ?? false }
            .flatMap(.merge) { fileURL -> SignalProducer<URL, CarthageError> in
                let fileName = fileURL.lastPathComponent
                let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
                let resolvedDestinationURL = destinationURL.resolvingSymlinksInPath()

                return Files.copyFile(from: fileURL, to: resolvedDestinationURL)
        }
    }

    /// Moves existing files sent from the producer into the given directory.
    ///
    /// Returns a producer that will send locations where the moved files are.
    func moveFileURLsIntoDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        return producer
            .filter { fileURL in (try? fileURL.checkResourceIsReachable()) ?? false }
            .flatMap(.merge) { fileURL -> SignalProducer<URL, CarthageError> in
                let fileName = fileURL.lastPathComponent
                let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
                let resolvedDestinationURL = destinationURL.resolvingSymlinksInPath()

                return Files.moveFile(from: fileURL, to: resolvedDestinationURL)
        }
    }
}
