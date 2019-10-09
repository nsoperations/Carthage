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
        public let localRepositoryPath: String?
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
                customCommitish: nil,
                dependenciesToBuild: dependenciesToUpdate
            )
        }

        /// If `checkoutAfterUpdate` and `buildAfterUpdate` are both true, this will
        /// be a producer representing the work necessary to build the project.
        ///
        /// Otherwise, this producer will be empty.
        public func buildProducer(project: Project) -> SignalProducer<(), CarthageError> {
            if checkoutAfterUpdate && buildAfterUpdate {
                return BuildCommand().build(project: project, options: buildCommandOptions)
            } else {
                return .empty
            }
        }

        fileprivate init(checkoutAfterUpdate: Bool,
                     buildAfterUpdate: Bool,
                     isVerbose: Bool,
                     logPath: String?,
                     localRepositoryPath: String?,
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
            self.localRepositoryPath = localRepositoryPath
        }

        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            let buildDescription = "skip the building of dependencies after updating\n(ignored if --no-checkout option is present)"
            let dependenciesUsage = "the dependency names to update, checkout and build"
            let option1 = Option(key: "checkout", defaultValue: true, usage: "skip the checking out of dependencies after updating")
            let option2 = Option(key: "build", defaultValue: true, usage: buildDescription)
            let option3 = Option(key: "verbose", defaultValue: false, usage: "print xcodebuild output inline (ignored if --no-build option is present), also prints resolver actions.")
            let option4 = Option<String?>(key: "log-path", defaultValue: nil, usage: "path to the xcode build output. A temporary file is used by default")
            let option5 = Option<String?>(key: "local-repository-path", defaultValue: nil, usage: "path to local repository containing the dependency information as was stored with a 'diagnose' command before. Implies --no-build and --no-checkout.")
            
            return curry(self.init)
                <*> mode <| option1
                <*> mode <| option2
                <*> mode <| option3
                <*> mode <| option4
                <*> mode <| option5
                <*> BuildOptions.evaluate(mode, addendum: "\n(ignored if --no-build option is present)")
                <*> CheckoutCommand.Options.evaluate(mode, dependenciesUsage: dependenciesUsage)
        }

        /// Attempts to load the project referenced by the options, and configure it
        /// accordingly.
        public func loadProject() -> SignalProducer<Project, CarthageError> {
            return checkoutOptions.loadProject(useNetrc: self.buildOptions.useNetrc)
        }
    }

    public let verb = "update"
    public let function = "Update and rebuild the project's dependencies"

    public func run(_ options: Options) -> Result<(), CarthageError> {

        let resolverEventLogger = ResolverEventLogger(colorOptions: options.checkoutOptions.colorOptions, verbose: options.isVerbose)
        var dependencyRetriever: DependencyRetrieverProtocol? = nil
        let effectiveOptions: Options
        
        if let localRepositoryURL = options.localRepositoryPath.map({ URL(fileURLWithPath: $0) }) {
            effectiveOptions = Options(checkoutAfterUpdate: false, buildAfterUpdate: false, isVerbose: options.isVerbose, logPath: options.logPath, localRepositoryPath: options.localRepositoryPath, buildOptions: options.buildOptions, checkoutOptions: options.checkoutOptions)
            dependencyRetriever = LocalDependencyStore(directoryURL: localRepositoryURL)
        } else {
            effectiveOptions = options
        }

        return options.loadProject()
            .flatMap(.merge) { project -> SignalProducer<(), CarthageError> in
                return project.updateDependencies(
                    shouldCheckout: effectiveOptions.checkoutAfterUpdate,
                    buildOptions: effectiveOptions.buildOptions,
                    dependenciesToUpdate: effectiveOptions.dependenciesToUpdate,
                    resolverEventObserver: { resolverEventLogger.log(event: $0) },
                    dependencyRetriever: dependencyRetriever
                ).then(effectiveOptions.buildProducer(project: project))
            }
            .waitOnCommand()
    }
}
