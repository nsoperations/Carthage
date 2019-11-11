import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveSwift

/// Type that encapsulates the configuration and evaluation of the `bootstrap` subcommand.
public struct BootstrapCommand: CommandProtocol {
    public let verb = "bootstrap"
    public let function = "Check out and build the project's dependencies"

    public func run(_ options: UpdateCommand.Options) -> Result<(), CarthageError> {
        // Reuse UpdateOptions, since all `bootstrap` flags should correspond to
        // `update` flags.
        return options.loadProject()
            .flatMap(.merge) { project -> SignalProducer<(), CarthageError> in
                if !FileManager.default.fileExists(atPath: project.resolvedCartfileURL.path) {
                    let formatting = options.checkoutOptions.colorOptions.formatting
                    carthage.printOut(formatting.bullets + "No Cartfile.resolved found, updating dependencies")
                    return project.updateDependencies(
                        shouldCheckout: options.checkoutAfterUpdate,
                        buildOptions: options.buildOptions).then(options.buildProducer(project: project))
                }

                let checkoutDependencies: SignalProducer<(), CarthageError>
                if options.checkoutAfterUpdate {
                    checkoutDependencies = project.checkoutResolvedDependencies(options.dependenciesToUpdate, buildOptions: options.buildOptions)
                } else {
                    checkoutDependencies = .empty
                }

                return checkoutDependencies.then(options.buildProducer(project: project))
            }
            .waitOnCommand()
    }
}
