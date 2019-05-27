import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveSwift
import XCDBLD
import Curry

/// Type that encapsulates the configuration and evaluation of the `archive` subcommand.
public struct ArchiveCommand: CommandProtocol {
    public struct Options: OptionsProtocol {
        public let outputPath: String?
        public let directoryPath: String
        public let colorOptions: ColorOptions
        public let frameworkNames: [String]

        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            let argumentUsage = "the names of the built frameworks to archive without any extension "
                + "(or blank to pick up the frameworks in the current project built by `--no-skip-current`)"

            let option1 = Option<String?>(
                key: "output",
                defaultValue: nil,
                usage: "the path at which to create the zip file (or blank to infer it from the first one of the framework names)"
            )
            let option2 = Option(
                key: "project-directory",
                defaultValue: FileManager.default.currentDirectoryPath,
                usage: "the directory containing the Carthage project"
            )

            return curry(self.init)
                <*> mode <| option1
                <*> mode <| option2
                <*> ColorOptions.evaluate(mode)
                <*> mode <| Argument(defaultValue: [], usage: argumentUsage, usageParameter: "framework names")
        }
    }

    public let verb = "archive"
    public let function = "Archives built frameworks into a zip that Carthage can use"

    // swiftlint:disable:next function_body_length
    public func run(_ options: Options) -> Result<(), CarthageError> {
        return archiveWithOptions(options)
            .waitOnCommand()
    }

    // swiftlint:disable:next function_body_length
    public func archiveWithOptions(_ options: Options) -> SignalProducer<URL, CarthageError> {
        let formatting = options.colorOptions.formatting
        let frameworkNames = options.frameworkNames
        let directoryURL = URL(fileURLWithPath: options.directoryPath)
        let customOutputURL = options.outputPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

        return Archive.archiveFrameworks(frameworkNames: frameworkNames, directoryURL: directoryURL, customOutputURL: customOutputURL, frameworkFoundHandler: { path in
            carthage.println(formatting.bullets + "Found " + formatting.path(path))
        }).on(value: { outputURL in
            carthage.println(formatting.bullets + "Created " + formatting.path(outputURL.path))
        })
    }
}
