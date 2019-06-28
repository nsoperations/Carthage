import Foundation
import Result
import ReactiveSwift
import SPMUtility

public enum ResolverEvent {
    case foundVersions(versions: [PinnedVersion], dependency: Dependency, versionSpecifier: VersionSpecifier)
    case foundTransitiveDependencies(transitiveDependencies: [(Dependency, VersionSpecifier)], dependency: Dependency, version: PinnedVersion)
    case failedRetrievingTransitiveDependencies(error: CarthageError, dependency: Dependency, version: PinnedVersion)
    case failedRetrievingVersions(error: CarthageError, dependency: Dependency, versionSpecifier: VersionSpecifier)
    case rejected(dependencySet: [Dependency: [PinnedVersion]], rejectionError: CarthageError)
}


/// Protocol for resolving acyclic dependency graphs.
public protocol ResolverProtocol {

    var events: Signal<ResolverEvent, NoError> { get }

    init(
        versionsForDependency: @escaping (Dependency) -> SignalProducer<PinnedVersion, CarthageError>,
        dependenciesForDependency: @escaping (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>,
        resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
    )

    func resolve(
        dependencies: [Dependency: VersionSpecifier],
        lastResolved: [Dependency: PinnedVersion]?,
        dependenciesToUpdate: [String]?
        ) -> SignalProducer<[Dependency: PinnedVersion], CarthageError>
}
