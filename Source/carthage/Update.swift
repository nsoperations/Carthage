import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveSwift
import Curry

/// Type that encapsulates the configuration and evaluation of the `update` subcommand.
public struct UpdateCommand: CommandProtocol {
    public struct Options: OptionsProtocol {
        public let checkoutAfterUpdate: Bool
        public let buildAfterUpdate: Bool
        public let isVerbose: Bool
        public let logPath: String?
        public let buildOptions: CarthageKit.BuildOptions
        public let checkoutOptions: CheckoutCommand.Options
        public let dependenciesToUpdate: [String]?

        /// The build options corresponding to these options.
        public var buildCommandOptions: BuildCommand.Options {
            return BuildCommand.Options(
                buildOptions: buildOptions,
                skipCurrent: true,
                colorOptions: checkoutOptions.colorOptions,
                isVerbose: isVerbose,
                directoryPath: checkoutOptions.directoryPath,
                logPath: logPath,
                archive: false,
                archiveOutputPath: nil,
                lockTimeout: checkoutOptions.lockTimeout,
                dependenciesToBuild: dependenciesToUpdate
            )
        }

        /// If `checkoutAfterUpdate` and `buildAfterUpdate` are both true, this will
        /// be a producer representing the work necessary to build the project.
        ///
        /// Otherwise, this producer will be empty.
        public var buildProducer: SignalProducer<(), CarthageError> {
            if checkoutAfterUpdate && buildAfterUpdate {
                return BuildCommand().buildWithOptions(buildCommandOptions)
            } else {
                return .empty
            }
        }

        private init(checkoutAfterUpdate: Bool,
                     buildAfterUpdate: Bool,
                     isVerbose: Bool,
                     logPath: String?,
                     buildOptions: BuildOptions,
                     checkoutOptions: CheckoutCommand.Options
            ) {
            self.checkoutAfterUpdate = checkoutAfterUpdate
            self.buildAfterUpdate = buildAfterUpdate
            self.isVerbose = isVerbose
            self.logPath = logPath
            self.buildOptions = buildOptions
            self.checkoutOptions = checkoutOptions
            self.dependenciesToUpdate = checkoutOptions.dependenciesToCheckout
        }

        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            let buildDescription = "skip the building of dependencies after updating\n(ignored if --no-checkout option is present)"
            let dependenciesUsage = "the dependency names to update, checkout and build"
            let option1 = Option(key: "checkout", defaultValue: true, usage: "skip the checking out of dependencies after updating")
            let option2 = Option(key: "build", defaultValue: true, usage: buildDescription)
            let option3 = Option(key: "verbose", defaultValue: false, usage: "print xcodebuild output inline (ignored if --no-build option is present), also prints resolver actions.")
            let option4 = Option<String?>(key: "log-path", defaultValue: nil, usage: "path to the xcode build output. A temporary file is used by default")
            let buildOptions = BuildOptions.evaluate(mode, addendum: "\n(ignored if --no-build option is present)")
            let checkoutOptions = CheckoutCommand.Options.evaluate(mode, dependenciesUsage: dependenciesUsage)

            return curry(self.init)
                <*> mode <| option1
                <*> mode <| option2
                <*> mode <| option3
                <*> mode <| option4
                <*> buildOptions
                <*> checkoutOptions
        }

        /// Attempts to load the project referenced by the options, and configure it
        /// accordingly.
        public func loadProject() -> SignalProducer<Project, CarthageError> {
            return checkoutOptions.loadProject()
        }
    }

    public let verb = "update"
    public let function = "Update and rebuild the project's dependencies"

    public func run(_ options: Options) -> Result<(), CarthageError> {

        let resolverEventLogger = ResolverEventLogger(colorOptions: options.checkoutOptions.colorOptions, verbose: options.isVerbose)

        return options.loadProject()
            .flatMap(.merge) { project -> SignalProducer<(), CarthageError> in
                return project.updateDependencies(
                    shouldCheckout: options.checkoutAfterUpdate,
                    buildOptions: options.buildOptions,
                    dependenciesToUpdate: options.dependenciesToUpdate,
                    resolverEventObserver: { resolverEventLogger.log(event: $0) }
                )
            }
            .then(options.buildProducer)
            .waitOnCommand()
    }
}
