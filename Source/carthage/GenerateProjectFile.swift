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
        public let colorOptions: ColorOptions

        private init(directoryPath: String, colorOptions: ColorOptions) {
            self.directoryPath = directoryPath
            self.colorOptions = colorOptions
        }

        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            return curry(self.init)
                <*> mode <| Option(key: "project-directory", defaultValue: FileManager.default.currentDirectoryPath, usage: "the directory containing the Carthage project")
                <*> ColorOptions.evaluate(mode)
        }
    }
    
    public let verb = "generate-project-file"
    public let function = "Generates a \(Constants.Project.projectCartfilePath) which describes the schemes, project/workspace and sdks to be built to avoid slow auto-discovery"

    public func run(_ options: GenerateProjectFileCommand.Options) -> Result<(), CarthageError> {
        let formatting = options.colorOptions.formatting
        carthage.printOut(formatting.bullets + "Generating \(Constants.Project.projectCartfilePath), this may take a few minutes")
        let observer: (ProjectBuildConfiguration) -> Void = { config in
            carthage.printOut(formatting.bullets + "Found \(config.scheme) in \(config.project) with skds: \(config.sdks)")
        }
        return Xcode.generateProjectCartfile(directoryURL: URL(fileURLWithPath: options.directoryPath), observer: observer)
            .attemptMap { projectCartfile -> Result<(), CarthageError> in
                let projectCartfileURL = URL(fileURLWithPath: options.directoryPath).appendingPathComponent(Constants.Project.projectCartfilePath)
                // Write file
                return Result(catching: {
                    do {
                        try projectCartfile.description.write(to: projectCartfileURL, atomically: true, encoding: .utf8)
                        carthage.printOut(formatting.bullets + "Successfully generated \(Constants.Project.projectCartfilePath)")
                    } catch {
                        throw CarthageError.writeFailed(projectCartfileURL, error as NSError)
                    }
                })
            }.waitOnCommand()
    }
}
