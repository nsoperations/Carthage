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
    let lockFileURL: URL
    
    init(lockFileURL: URL) {
        self.lockFileURL = lockFileURL
    }
    
    deinit {
        unlock()
    }
    
    /// Tries a lock with an optional timeoutDate. If the lock was acquired before the timeout date true will be returned, false otherwise.
    func lock(timeoutDate: Date?) -> Bool {
        while true {
            guard let _ = try? FileManager.default.createDirectory(at: lockFileURL.deletingLastPathComponent(), withIntermediateDirectories: true) else {
                return false
            }
            let task = Process()
            task.launchPath = "/usr/bin/shlock"
            task.arguments = ["-f", lockFileURL.path, "-p", processId]
            task.launch()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                print("Locked file at url: \(lockFileURL)")
                return true
            }
            if timeoutDate.map({ $0.timeIntervalSinceNow <= 0 }) ?? true {
                break
            }
            print("Waiting for lock on file at url: \(lockFileURL)")
            Thread.sleep(forTimeInterval: FileLock.retryInterval)
        }
        print("Could not lock file at url: \(lockFileURL)")
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
    
    /// Unlocks the lock, returns true if lock was released, false otherwise (e.g. because the lock file did not exist anymore).
    @discardableResult
    func unlock() -> Bool {
        do {
            try FileManager.default.removeItem(at: self.lockFileURL)
            print("Unlocked file: \(self.lockFileURL)")
            return true
        } catch {
            return false
        }
    }
    
    private var processId: String {
        return String(ProcessInfo.processInfo.processIdentifier)
    }
}

/// Class which protects a specific URL for reading/writing using a FileLock. The FileLock uses a lock file which is stored in the specified lockFileDirectory.
final class URLLock: Lock {

    /// Default strategy for constructing a lock file URL from the URL to protect.
    static let defaultLockFileNamingStrategy: (URL) -> URL = { (url) -> URL in
        let parentURL = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        return parentURL.appendingPathComponent(".\(fileName).lock")
    }
    
    let url: URL
    private let fileLock: FileLock
    
    convenience init(url: URL, lockFileNamingStrategy: (URL) -> URL = URLLock.defaultLockFileNamingStrategy) {
        self.init(url: url, lockFileURL: lockFileNamingStrategy(url))
    }

    init(url: URL, lockFileURL: URL) {
        self.url = url
        self.fileLock = FileLock(lockFileURL: lockFileURL)
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
