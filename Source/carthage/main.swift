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
registry.register(DependenciesHashCommand())

#if DEBUG
var logTasks = false

if let index = CommandLine.arguments.firstIndex(of: "--log-tasks") {
    logTasks = true
    CommandLine.arguments.remove(at: index)
}

let start = Date()
let debugEventLogger = TaskDebugEventLogger { printErr($0) }
Task.debugEvents.observeValues { event in
    if logTasks {
        debugEventLogger.logEvent(event)
    }
}
#endif

let helpCommand = HelpCommand(registry: registry)
registry.register(helpCommand)

registry.main(defaultVerb: helpCommand.verb, successHandler: {
    
    #if DEBUG
    if logTasks {
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
    }
    
    #endif
    
}, errorHandler: { error in
    printErr("")
    printErr("error: " + error.description)
    printErr("")
})
