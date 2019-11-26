import Foundation
import Result
import ReactiveSwift

/**
 Resolver implementation based on an optimized Backtracking Algorithm.

 See: https://en.wikipedia.org/wiki/Backtracking

 The implementation does not use the reactive stream APIs to be able to keep the time complexity down and have a simple algorithm.
 */
public final class BackTrackingResolver: ResolverProtocol {

    /// DependencyCrawler events signal
    public let events: Signal<ResolverEvent, NoError>
    private let eventPublisher: Signal<ResolverEvent, NoError>.Observer
    private let projectDependencyRetriever: DependencyRetrieverProtocol

    /**
     Current resolver state, accepted or rejected.
     */
    private enum ResolverState {
        case rejected, accepted
    }

    private typealias ResolverEvaluation = (state: ResolverState, dependencySet: DependencySet)

    /**
     Instantiates a resolver with the given strategies for retrieving the versions for a specific dependency, the set of dependencies for a pinned dependency and
     for retrieving a pinned git reference.

     versionsForDependency - Sends a stream of available versions for a
     dependency.
     dependenciesForDependency - Loads the dependencies for a specific
     version of a dependency.
     resolvedGitReference - Resolves an arbitrary Git reference to the
     latest object.
     */
    public init(projectDependencyRetriever: DependencyRetrieverProtocol) {
        self.projectDependencyRetriever = projectDependencyRetriever

        let (signal, observer) = Signal<ResolverEvent, NoError>.pipe()
        events = signal
        eventPublisher = observer
    }

    /**
     Attempts to determine the most appropriate valid version to use for each
     dependency in `dependencies`, and all nested dependencies thereof.

     Sends a dictionary with each dependency and its resolved version.
     */
    public func resolve(
        dependencies: [Dependency: VersionSpecifier],
        lastResolved: [Dependency: PinnedVersion]? = nil,
        dependenciesToUpdate: [String]? = nil
        ) -> SignalProducer<[Dependency: PinnedVersion], CarthageError> {
        
        let resolve: SignalProducer<[Dependency : PinnedVersion], CarthageError> = SignalProducer { () -> Result<[Dependency : PinnedVersion], CarthageError> in

            let result: Result<[Dependency: PinnedVersion], CarthageError>

            let pinnedVersions = lastResolved ?? [Dependency: PinnedVersion]()
            let resolverContext = ResolverContext(projectDependencyRetriever: self.projectDependencyRetriever,
                                                  pinnedVersions: pinnedVersions)

            resolverContext.eventObserver = self.eventPublisher.send

            let updatableDependencyNames = dependenciesToUpdate.map { Set($0) } ?? Set()
            let requiredDependencies: [DependencyEntry] = Array(dependencies)

            do {
                let dependencySet = try DependencySet(requiredDependencies: requiredDependencies,
                                                      updatableDependencyNames: updatableDependencyNames,
                                                      resolverContext: resolverContext)
                let resolverResult = try self.backtrack(dependencySet: dependencySet, rootDependencies: requiredDependencies.map { $0.0 })

                switch resolverResult.state {
                case .accepted:
                    try resolverResult.dependencySet.eliminateSameNamedDependencies(rootEntries: requiredDependencies)
                case .rejected:
                    if let rejectionError = dependencySet.rejectionError {
                        if case .unsatisfiableDependencyList(_) = rejectionError {
                            throw CarthageError.unsatisfiableDependencyList(dependenciesToUpdate ?? [])
                        }
                        throw rejectionError
                    } else {
                        throw CarthageError.internalError(description: "No dependency set was resolved and no resolver error was present. This should never happen.")
                    }
                }
                result = .success(resolverResult.dependencySet.resolvedDependencies)
            } catch let carthageError as CarthageError {
                result = .failure(carthageError)
            } catch let error {
                let carthageError = CarthageError.internalError(description: error.localizedDescription)
                result = .failure(carthageError)
            }

            return result
        }
        return self.projectDependencyRetriever.prefetch(dependencies: dependencies, includedDependencyNames: dependenciesToUpdate).then(resolve)
    }

    /**
     Recursive backtracking algorithm to resolve the dependency set.

     See: https://en.wikipedia.org/wiki/Backtracking
     */
    private func backtrack(dependencySet: DependencySet, rootDependencies: [Dependency]) throws -> (state: ResolverState, dependencySet: DependencySet) {
        if dependencySet.isRejected {
            eventPublisher.send(value: ResolverEvent.rejected(dependencySet: dependencySet.pinnedVersions, rejectionError: dependencySet.rejectionError!))
            return (.rejected, dependencySet)
        } else if dependencySet.isComplete {
            let valid = try dependencySet.validateForCyclicDepencies(rootDependencies: rootDependencies)
            if valid {
                return (.accepted, dependencySet)
            } else {
                return (.rejected, dependencySet)
            }
        }

        var result: ResolverEvaluation?
        var firstRejectionError: CarthageError?
        while result == nil {
            // Keep iterating until there are no subsets to resolve anymore
            if let subSet = try dependencySet.popSubSet() {
                let subResult = try backtrack(dependencySet: subSet, rootDependencies: rootDependencies)
                switch subResult.state {
                case .rejected:
                    if subSet === dependencySet {
                        result = (.rejected, subSet)
                    }
                    if subSet.rejectionError != nil && firstRejectionError == nil {
                        firstRejectionError = subSet.rejectionError
                    }
                case .accepted:
                    // Set contains all dependencies, we've got a winner
                    result = (.accepted, subResult.dependencySet)
                }
            } else {
                // All done
                result = (.rejected, dependencySet)
                if dependencySet.rejectionError == nil {
                    dependencySet.rejectionError = firstRejectionError
                }
            }
        }

        // By definition result is not nil at this point (while loop only breaks when result is not nil)
        return result!
    }
}
