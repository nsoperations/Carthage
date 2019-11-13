import CarthageKit
import Commandant
import Foundation
import ReactiveSwift
import Result
import Curry

/// Type that encapsulates the configuration and evaluation of the `validate` subcommand.
public struct GenerateProjectFileCommand: CommandProtocol {
    
    public struct Options: OptionsProtocol {
        public let directoryPath: String

        private init(directoryPath: String) {
            self.directoryPath = directoryPath
        }

        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            return curry(self.init)
                <*> mode <| Option(key: "project-directory", defaultValue: FileManager.default.currentDirectoryPath, usage: "the directory containing the Carthage project")
        }
    }
    
    public let verb = "generate-projectfile"
    public let function = "Generates a Cartfile.project which describes the schemes, project/workspace and sdks to be built to avoid slow auto-discovery"

    public func run(_ options: GenerateProjectFileCommand.Options) -> Result<(), CarthageError> {
        return Xcode.generateProjectCartfile(directoryURL: URL(fileURLWithPath: options.directoryPath))
            .on(value: { projectFile in
                carthage.printOut(projectFile.description)
            })
            .waitOnCommand()
    }
}
