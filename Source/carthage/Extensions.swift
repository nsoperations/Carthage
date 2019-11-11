// This file contains extensions to anything that's not appropriate for
// CarthageKit.

import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveSwift
import ReactiveTask

private let outputQueue = { () -> DispatchQueue in
    let targetQueue = DispatchQueue.global(qos: .userInitiated)
    let queue = DispatchQueue(label: "org.carthage.carthage.outputQueue", target: targetQueue)

    atexit_b {
        queue.sync(flags: .barrier) {}
    }

    return queue
}()

/// A thread-safe version of Swift's standard println().
internal func printOut(_ object: Any) {
    outputQueue.async {
        fputs(String(describing: object) + "\n", stdout)
    }
}

internal func printErr(_ object: Any) {
    outputQueue.async {
        fputs(String(describing: object) + "\n", stderr)
    }
}

extension String {
    /// Split the string into substrings separated by the given separators.
    internal func split(maxSplits: Int = .max, omittingEmptySubsequences: Bool = true, separators: [Character] = [ ",", " " ]) -> [String] {
        return split(maxSplits: maxSplits, omittingEmptySubsequences: omittingEmptySubsequences, whereSeparator: separators.contains)
            .map(String.init)
    }
}

extension SignalProducer where Error == CarthageError {
    /// Waits on a SignalProducer that implements the behavior of a CommandProtocol.
    internal func waitOnCommand() -> Result<(), CarthageError> {
        let result = producer
            .then(SignalProducer<(), CarthageError>.empty)
            .wait()

        Task.waitForAllTaskTermination()
        return result
    }
}

extension GitURL: ArgumentProtocol {
    public static let name = "URL"

    public static func from(string: String) -> GitURL? {
        return self.init(string)
    }
}
