import CarthageKit
import Commandant
import Foundation
import ReactiveSwift
import ReactiveTask
import Result

setlinebuf(stdout)

guard Git.ensureGitVersion().first()?.value == true else {
    printErr("Carthage requires git \(Git.carthageRequiredGitVersion) or later.\n")
    exit(EXIT_FAILURE)
}

if let remoteVersion = remoteVersion(), CarthageKitVersion.current.value < remoteVersion {
    printErr("Please update to the latest Carthage version: \(remoteVersion). You currently are on \(CarthageKitVersion.current.value)" + "\n")
}

if let carthagePath = Bundle.main.executablePath {
    setenv("CARTHAGE_PATH", carthagePath, 0)
}

let registry = CommandRegistry<CarthageError>()
registry.register(ArchiveCommand())
registry.register(BootstrapCommand())
registry.register(BuildCommand())
registry.register(CheckoutCommand())
registry.register(CopyFrameworksCommand())
registry.register(FetchCommand())
registry.register(OutdatedCommand())
registry.register(UpdateCommand())
registry.register(ValidateCommand())
registry.register(VersionCommand())
registry.register(DiagnoseCommand())
registry.register(SwiftVersionCommand())
registry.register(GenerateProjectFileCommand())

#if DEBUG
let start = Date()
Task.debugEvents.observeValues { event in
    switch event {
    case let .cacheHit(task, duration):
        printErr(String(format: "Task #\(task.identifier) cache hit in %.2fs: \(task)", duration))
    case let .duplicate(task):
        printErr("Task #\(task.identifier) has been executed before, consider caching: \(task)")
    case let .launch(task):
        printErr("Task #\(task.identifier) launched: \(task)")
    case let .launchFailure(task, error):
        printErr("Task #\(task.identifier) launch failed: \(error)")
    case let .success(task, duration, _):
        printErr(String(format: "Task #\(task.identifier) finished successfully in %.2fs", duration))
    case let .failure(task, duration, terminationStatus, error):
        printErr(String(format: "Task #\(task.identifier) failed with exit code \(terminationStatus) in %.2fs" + (error.map {": " + $0} ?? ""), duration))
    }
}
#endif

let helpCommand = HelpCommand(registry: registry)
registry.register(helpCommand)

registry.main(defaultVerb: helpCommand.verb, successHandler: {
    
    #if DEBUG
    let totalDuration = Date().timeIntervalSince(start)
    
    printErr("-------------------------------------------------------------------------------")
    printErr("")
    printErr(String(format: "Total duration: %.2fs.", totalDuration))
    printErr("")
    
    let taskHistory: [Task: TimeInterval] = Task.history
    
    let totalTaskDuration: TimeInterval = taskHistory.values.reduce(0.0) { $0 + $1 }
    
    printErr(String(format: "Total duration of tasks: %.2fs.", totalTaskDuration))
    
    printErr("")
    printErr("Ordered tasks by duration:")
    printErr("")
    
    let orderedTasks: [(key: Task, value: TimeInterval)] = taskHistory.sorted {
        $0.value > $1.value
    }
    
    for entry in orderedTasks {
        printErr(String(format: "Task #\(entry.key.identifier) took %.2fs: \(entry.key)", entry.value))
    }
    
    printErr("")
    printErr("-------------------------------------------------------------------------------")
    
    #endif
    
}, errorHandler: { error in
    printErr(error.description + "\n")
})
