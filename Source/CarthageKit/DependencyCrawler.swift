import Foundation
import Result
import ReactiveSwift

/// Class which logs all dependencies it encounters and stores them in the specified local store to be able to support subsequent offline test cases.
public final class DependencyCrawler {
    private let store: LocalDependencyStore
    private let dependencyRetriever: DependencyRetrieverProtocol
    private let ignoreErrors: Bool

    /// Specify mappings to anonymize private dependencies (which may not be disclosed as part of the diagnostics)
    private var dependencyMappings: [Dependency: Dependency]?
    private let eventPublisher: Signal<ResolverEvent, NoError>.Observer

    /// DependencyCrawler events signal
    public let events: Signal<ResolverEvent, NoError>

    private enum DependencyCrawlerError: Error {
        case versionRetrievalFailure(message: String)
        case dependencyRetrievalFailure(message: String)
    }

    /// Initializes with implementations for retrieving the versions, transitive dependencies and git references.
    ///
    /// Uses the supplied local dependency store to store the encountered dependencies.
    ///
    /// Optional mappings may be specified to anonymize the encountered dependencies (thereby removing sensitive information).
    ///
    /// If ignoreErrors is true, any error during retrieval of the dependencies will not be fatal but will result in an empty array instead.
    public init(
        dependencyRetriever: DependencyRetrieverProtocol,
        store: LocalDependencyStore,
        mappings: [Dependency: Dependency]? = nil,
        ignoreErrors: Bool = false
        ) {
        self.store = store
        self.dependencyMappings = mappings
        self.ignoreErrors = ignoreErrors
        self.dependencyRetriever = dependencyRetriever

        let (signal, observer) = Signal<ResolverEvent, NoError>.pipe()
        events = signal
        eventPublisher = observer
    }

    /// Recursively traverses the supplied dependencies taking into account their compatibleWith version specifiers.
    ///
    /// Stores all dependencies in the LocalDependencyStore.
    ///
    /// Returns a dictionary of all encountered dependencies with as value a set of all their encountered versions.
    public func traverse(dependencies: [Dependency: VersionSpecifier]) -> Result<[Dependency: Set<PinnedVersion>], CarthageError> {
        let result: Result<[Dependency: Set<PinnedVersion>], CarthageError>
        do {
            var handledDependencies = Set<PinnedDependency>()
            var cachedVersionSets = [DependencyKey: [PinnedVersion]]()
            try traverse(dependencies: Array(dependencies),
                         handledDependencies: &handledDependencies,
                         cachedVersionSets: &cachedVersionSets)
            result = .success(handledDependencies.dictionaryRepresentation)
        } catch let error as CarthageError {
            result = .failure(error)
        } catch {
            result = .failure(CarthageError.internalError(description: error.localizedDescription))
        }
        return result
    }

    private func traverse(dependencies: [(Dependency, VersionSpecifier)],
                          handledDependencies: inout Set<PinnedDependency>,
                          cachedVersionSets: inout [DependencyKey: [PinnedVersion]]) throws {
        for (dependency, versionSpecifier) in dependencies {
            let versionSet = try findAllVersions(for: dependency,
                                                 compatibleWith: versionSpecifier,
                                                 cachedVersionSets: &cachedVersionSets)
            for version in versionSet {
                let pinnedDependency = PinnedDependency(dependency: dependency, pinnedVersion: version)

                if !handledDependencies.contains(pinnedDependency) {
                    handledDependencies.insert(pinnedDependency)

                    let transitiveDependencies = try findDependencies(for: dependency, version: version)
                    try traverse(dependencies: transitiveDependencies,
                                 handledDependencies: &handledDependencies,
                                 cachedVersionSets: &cachedVersionSets)
                }
            }
        }
    }

    private func findAllVersions(for dependency: Dependency,
                                 compatibleWith versionSpecifier: VersionSpecifier,
                                 cachedVersionSets: inout [DependencyKey: [PinnedVersion]]) throws -> [PinnedVersion] {
        do {
            let versionSet: [PinnedVersion]
            let dependencyKey = DependencyKey(dependency: dependency, versionSpecifier: versionSpecifier)
            if let cachedVersionSet = cachedVersionSets[dependencyKey] {
                versionSet = cachedVersionSet
            } else {
                let pinnedVersionsProducer: SignalProducer<PinnedVersion, CarthageError>
                var gitReference: String?

                switch versionSpecifier {
                case .gitReference(let hash):
                    pinnedVersionsProducer = dependencyRetriever.resolvedGitReference(dependency, reference: hash)
                    gitReference = hash
                default:
                    pinnedVersionsProducer = dependencyRetriever.versions(for: dependency)
                }

                guard let pinnedVersions: [PinnedVersion] = try pinnedVersionsProducer.collect().first()?.get() else {
                    throw DependencyCrawlerError.versionRetrievalFailure(message: "Could not collect versions for dependency: \(dependency) and versionSpecifier: \(versionSpecifier)")
                }
                cachedVersionSets[dependencyKey] = pinnedVersions

                let storedDependency = self.dependencyMappings?[dependency] ?? dependency
                try store.storePinnedVersions(pinnedVersions, for: storedDependency, gitReference: gitReference).get()

                versionSet = pinnedVersions
            }

            let filteredVersionSet: [PinnedVersion]
            if case .gitReference = versionSpecifier {
                // Do not filter git references, because they are by definition compatible with the pinned versions that were retrieved.
                filteredVersionSet = versionSet
            } else {
                filteredVersionSet = versionSet.filter { pinnedVersion -> Bool in
                    versionSpecifier.isSatisfied(by: pinnedVersion)
                }
            }

            eventPublisher.send(value:
                .foundVersions(versions: filteredVersionSet, dependency: dependency, versionSpecifier: versionSpecifier)
            )

            return filteredVersionSet
        } catch let error as CarthageError {

            eventPublisher.send(value:
                .failedRetrievingVersions(error: error, dependency: dependency, versionSpecifier: versionSpecifier)
            )

            if ignoreErrors {
                return [PinnedVersion]()
            } else {
                throw error
            }
        }
    }

    private func findDependencies(for dependency: Dependency, version: PinnedVersion) throws -> [(Dependency, VersionSpecifier)] {
        do {
            guard let transitiveDependencies: [(Dependency, VersionSpecifier)] = try dependencyRetriever.dependencies(for: dependency, version: version).collect().first()?.get() else {
                throw DependencyCrawlerError.dependencyRetrievalFailure(message: "Could not find transitive dependencies for dependency: \(dependency), version: \(version)")
            }

            let storedDependency = self.dependencyMappings?[dependency] ?? dependency
            let storedTransitiveDependencies = transitiveDependencies.map { transitiveDependency, versionSpecifier -> (Dependency, VersionSpecifier) in
                let storedTransitiveDependency = self.dependencyMappings?[transitiveDependency] ?? transitiveDependency
                return (storedTransitiveDependency, versionSpecifier)
            }
            try store.storeTransitiveDependencies(storedTransitiveDependencies, for: storedDependency, version: version).get()

            eventPublisher.send(value:
                .foundTransitiveDependencies(transitiveDependencies: transitiveDependencies, dependency: dependency, version: version)
            )

            return transitiveDependencies
        } catch let error as CarthageError {

            eventPublisher.send(value:
                .failedRetrievingTransitiveDependencies(error: error, dependency: dependency, version: version)
            )

            if ignoreErrors {
                return [(Dependency, VersionSpecifier)]()
            } else {
                throw error
            }
        }
    }
}

extension Sequence where Element == PinnedDependency {
    fileprivate var dictionaryRepresentation: [Dependency: Set<PinnedVersion>] {
        return self.reduce(into: [Dependency: Set<PinnedVersion>]()) { dict, pinnedDependency in
            var set = dict[pinnedDependency.dependency, default: Set<PinnedVersion>()]
            set.insert(pinnedDependency.pinnedVersion)
            dict[pinnedDependency.dependency] = set
        }
    }
}

private struct DependencyKey: Hashable {
    let dependency: Dependency
    let gitReference: String?

    init(dependency: Dependency, gitReference: String?) {
        self.dependency = dependency
        self.gitReference = gitReference
    }

    init(dependency: Dependency, versionSpecifier: VersionSpecifier) {
        var gitReference: String?
        if case let VersionSpecifier.gitReference(reference) = versionSpecifier {
            gitReference = reference
        }
        self.init(dependency: dependency, gitReference: gitReference)
    }
}
