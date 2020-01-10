import CarthageKit
import Commandant
import Foundation
import Result
import Curry
import ReactiveSwift

/// Type that encapsulates the configuration and evaluation of the `version` subcommand.
public struct DependenciesHashCommand: CommandProtocol {
    
    public struct Options: OptionsProtocol {
        public let directoryPath: String

        private init(directoryPath: String) {
            self.directoryPath = directoryPath
        }

        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            return curry(self.init)
                <*> mode <| Option(key: "project-directory", defaultValue: FileManager.default.currentDirectoryPath, usage: "the directory containing the Carthage project")
        }

        /// Attempts to load the project referenced by the options, and configure it
        /// accordingly.
        public func loadProject() -> SignalProducer<Project, CarthageError> {
            let directoryURL = URL(fileURLWithPath: self.directoryPath, isDirectory: true)
            let project = Project(directoryURL: directoryURL, useNetrc: false)
            return SignalProducer(value: project)
        }
    }
    
    public let verb = "dependencies-hash"
    public let function = "Calculate the hash of the transitive dependencies as in the current Cartfile.resolved which is used by the cache implementation for cross-reference."
    
    public func run(_ options: Options) -> Result<(), CarthageError> {
        return options.loadProject().flatMap(.merge) { project -> SignalProducer<(), CarthageError> in
            return project.hashForResolvedDependencies().map { hash in
                carthage.printOut(hash)
                return ()
            }
        }.waitOnCommand()
    }
}

