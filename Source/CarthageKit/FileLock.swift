//
//  FileLock.swift
//  CarthageKit
//
//  Created by Werner Altewischer on 05/04/2019.
//

import Foundation
import Result
import ReactiveSwift
import ReactiveTask

/// Protocol describing the public interface for concrete implementations of lock
protocol Lock {

    /// Whether or not the lock is currently locked
    var isLocked: Bool { get }

    /// Obtain a lock before the specified timeoutDate (or return immediately if not specified). Returns true if successful, false otherwise.
    func lock(timeoutDate: Date?) -> Bool

    /// Unlocks the lock. Returns true if successful, false otherwise.
    @discardableResult
    func unlock() -> Bool
}

extension Lock {
    /// Tries a lock with the specified timeout interval
    func lock(timeout: TimeInterval) -> Bool {
        let timeoutDate = Date(timeIntervalSinceNow: timeout)
        return lock(timeoutDate: timeoutDate)
    }

    /// Tries a lock without timeout, returns instantly with false if no lock could be obtained.
    func lock() -> Bool {
        return lock(timeoutDate: nil)
    }
}

/// Mutual exclusive lock using the system utility shlock as implementation.
/// The lock is retained by processId, which means that there can only be one lock for a specific file per application instance.
/// In particular shlock ensures that in case the application crashes the lock will automatically be invalidated (because the processId is no longer valid).
/// If the instance of this class holding the lock is released from memory, the lock will automatically be removed.
final class FileLock: Lock {

    private static let retryInterval = 1.0
    private var wasLocked = false
    let lockFileURL: URL
    let isRecursive: Bool
    var onWait: ((FileLock) -> Void)?

    init(lockFileURL: URL, isRecursive: Bool = false) {
        self.lockFileURL = lockFileURL
        self.isRecursive = isRecursive
    }

    deinit {
        unlock()
    }
    
    /// Tries a lock with an optional timeoutDate. If the lock was acquired before the timeout date true will be returned, false otherwise.
    func lock(timeoutDate: Date?) -> Bool {
        var waiting = false
        while true {
            let processId = self.processId
            if self.isRecursive && processId == self.lockingProcessId {
                return true
            }
            guard let _ = try? FileManager.default.createDirectory(at: lockFileURL.deletingLastPathComponent(), withIntermediateDirectories: true) else {
                return false
            }
            let task = Process()
            task.launchPath = "/usr/bin/shlock"
            task.arguments = ["-f", lockFileURL.path, "-p", String(processId)]
            task.launch()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                wasLocked = true
                return true
            }
            if timeoutDate.map({ $0.timeIntervalSinceNow <= 0 }) ?? true {
                break
            }
            if !waiting {
                onWait?(self)
                waiting = true
            }

            let sleepDate = Date(timeIntervalSinceNow: FileLock.retryInterval)
            Thread.sleep(until: min(timeoutDate ?? sleepDate, sleepDate))
        }
        return false
    }

    /// Returns true if currently locked, false otherwise
    var isLocked: Bool {
        guard FileManager.default.fileExists(atPath: lockFileURL.path) else {
            return false
        }
        let task = Process()
        task.launchPath = "/usr/bin/shlock"
        task.arguments = ["-f", lockFileURL.path]
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    var lockingProcessId: Int? {
        guard isLocked else {
            return nil
        }
        guard let contents = try? String(contentsOfFile: lockFileURL.path) else {
            return nil
        }
        return Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Unlocks the lock, returns true if lock was released, false otherwise (e.g. because the lock file did not exist anymore).
    @discardableResult
    func unlock() -> Bool {
        guard wasLocked else {
            return false
        }
        wasLocked = false
        do {
            try FileManager.default.removeItem(at: self.lockFileURL)
            return true
        } catch {
            return false
        }
    }

    private var processId: Int {
        return Int(ProcessInfo.processInfo.processIdentifier)
    }
}

/// Class which protects a specific URL for reading/writing using a FileLock. The FileLock uses a lock file which is stored in the specified lockFileDirectory.
final class URLLock: Lock {

    /// Default strategy for constructing a lock file URL from the URL to protect.
    static let defaultLockFileNamingStrategy: (URL) -> URL = { url -> URL in
        let parentURL = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        return parentURL.appendingPathComponent(".\(fileName).lock")
    }

    let url: URL
    private let fileLock: FileLock
    var onWait: ((URLLock) -> Void)? {
        didSet {
            fileLock.onWait = { [weak self] fileLock in
                guard let self = self else { return }
                self.onWait?(self)
            }
        }
    }

    convenience init(url: URL, isRecursive: Bool = false, lockFileNamingStrategy: (URL) -> URL = URLLock.defaultLockFileNamingStrategy) {
        self.init(url: url, lockFileURL: lockFileNamingStrategy(url), isRecursive: isRecursive)
    }

    convenience init(url: URL, lockFileURL: URL, isRecursive: Bool = false) {
        self.init(url: url, fileLock: FileLock(lockFileURL: lockFileURL, isRecursive: isRecursive))
    }

    init(url: URL, fileLock: FileLock) {
        self.url = url
        self.fileLock = fileLock
    }

    func lock(timeoutDate: Date?) -> Bool {
        return fileLock.lock(timeoutDate: timeoutDate)
    }

    var isLocked: Bool {
        return fileLock.isLocked
    }

    @discardableResult
    func unlock() -> Bool {
        return fileLock.unlock()
    }
}

extension URLLock {
    static var globalWaitHandler: ((URLLock) -> Void)?

    static func lockReactive(url: URL, timeout: Int? = nil, recursive: Bool = false, onWait: ((URLLock) -> Void)? = URLLock.globalWaitHandler) -> SignalProducer<URLLock, CarthageError> {
        return SignalProducer({ () -> Result<URLLock, CarthageError> in
            let lock = URLLock(url: url, isRecursive: recursive)
            lock.onWait = onWait
            guard lock.lock(timeout: timeout == nil ? TimeInterval(Int.max) : TimeInterval(timeout!)) else {
                return .failure(CarthageError.lockError(url: url, timeout: timeout))
            }
            return .success(lock)
        })
    }
}
