#if DEBUG

import Foundation

public final class TaskDebugEventLogger {
    
    private final let print: (Any) -> Void
    
    public init(logFunction: @escaping (Any) -> Void) {
        self.print = logFunction
    }
    
    public func logEvent(_ event: TaskDebugEvent) {
        switch event {
        case let .cacheHit(task):
            print("Task #\(task.identifier) cache hit: \(task)")
        case let .duplicate(task):
            print("Task #\(task.identifier) has been executed before, consider caching: \(task)")
        case let .launch(task):
            print("Task #\(task.identifier) launched: \(task)")
        case let .launchFailure(task, error):
            print("Task #\(task.identifier) launch failed: \(error)")
        case let .success(task, duration, _):
            print(String(format: "Task #\(task.identifier) finished successfully in %.2fs", duration))
        case let .failure(task, duration, terminationStatus, error):
            print(String(format: "Task #\(task.identifier) failed with exit code \(terminationStatus) in %.2fs" + (error.map {": " + $0} ?? ""), duration))
        }
    }
}

#endif
