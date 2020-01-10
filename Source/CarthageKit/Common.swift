import Foundation
import Result

func tryMapError<T>(mapError: (Swift.Error) -> Swift.Error, perform: () throws -> T) rethrows -> T {
    do {
        return try perform()
    } catch {
        throw mapError(error)
    }
}

func readURL<T>(_ url: URL, block: (URL) throws -> T) rethrows -> T {
    return try tryMapError(mapError: { CarthageError.readFailed(url, $0 as NSError) }, perform: { try block(url) })
}

func writeURL<T>(_ url: URL, block: (URL) throws -> T) rethrows -> T {
    return try tryMapError(mapError: { CarthageError.writeFailed(url, $0 as NSError) }, perform: { try block(url) })
}

let globalConcurrentProducerQueue = ConcurrentProducerQueue(name: "org.carthage.CarthageKit.globalConcurrentQueue", limit: Constants.concurrencyLimit)
