import Foundation
import Result

/// Identifies a dependency, its pinned version, and its compatible and incompatible requirements
public struct CompatibilityInfo: Equatable {
    public static func == (lhs: CompatibilityInfo, rhs: CompatibilityInfo) -> Bool {
        return lhs.dependency == rhs.dependency &&
            lhs.pinnedVersion == rhs.pinnedVersion &&
            lhs.requirements == rhs.requirements
    }

    public typealias Requirement = (Dependency, VersionSpecifier)

    public struct Requirements {

        fileprivate var lookupTable: [Dependency?: [Dependency: VersionSpecifier]]

        public init() {
            self.init([Dependency?: [Dependency: VersionSpecifier]]())
        }

        public init(_ lookupTable: [Dependency?: [Dependency: VersionSpecifier]]) {
            self.lookupTable = lookupTable
        }

        var count: Int {
            return self.lookupTable.count
        }

        mutating func setRequirement(_ requirement: Requirement, from definingDependency: Dependency?) {
            self.lookupTable[definingDependency, default: [Dependency: VersionSpecifier]()][requirement.0] = requirement.1
        }

        func hasRequirement(for dependency: Dependency, from definingDependency: Dependency?) -> Bool {
            return self.requirements(from: definingDependency)?[dependency] != nil
        }

        func requirements(from definingDependency: Dependency?) -> [Dependency: VersionSpecifier]? {
            return self.lookupTable[definingDependency]
        }
    }

    //public typealias Requirements = [Dependency: [Dependency: VersionSpecifier]]

    /// The dependency
    public let dependency: Dependency

    /// The pinned version of this dependency
    public let pinnedVersion: PinnedVersion

    /// Requirements with which the pinned version of this dependency may or may not be compatible
    private let requirements: [Dependency?: VersionSpecifier]

    private let projectDependencyRetriever: DependencyRetrieverProtocol

    public init(dependency: Dependency, pinnedVersion: PinnedVersion, requirements: [Dependency?: VersionSpecifier], projectDependencyRetriever: DependencyRetrieverProtocol) {
        self.dependency = dependency
        self.pinnedVersion = pinnedVersion
        self.requirements = requirements
        self.projectDependencyRetriever = projectDependencyRetriever
    }

    /// Requirements which are compatible with the pinned version of this dependency
    public var compatibleRequirements: [Dependency?: VersionSpecifier] {
        return requirements.filter { dependency, versionSpecifier in
            let effectiveVersionSpecifier = (try? versionSpecifier.effectiveSpecifier(for: self.dependency, retriever: projectDependencyRetriever)) ?? versionSpecifier
            return effectiveVersionSpecifier.isSatisfied(by: pinnedVersion)
        }
    }

    /// Requirements which are not compatible with the pinned version of this dependency
    public var incompatibleRequirements: [Dependency?: VersionSpecifier] {
        return requirements.filter { dependency, versionSpecifier in
            let effectiveVersionSpecifier = (try? versionSpecifier.effectiveSpecifier(for: self.dependency, retriever: projectDependencyRetriever)) ?? versionSpecifier
            return !effectiveVersionSpecifier.isSatisfied(by: pinnedVersion)
        }
    }

    /// Accepts a dictionary which maps a dependency to the pinned versions of the dependencies it requires.
    /// Returns an inverted dictionary which maps a dependency to the dependencies that require it and the pinned version required
    /// e.g. [A: [B: 1, C: 2]] -> [B: [A: 1], C: [A: 2]]
    public static func invert(requirements: Requirements) -> Result<[Dependency: [Dependency?: VersionSpecifier]], CarthageError> {
        var invertedRequirements = [Dependency: [Dependency?: VersionSpecifier]]()
        for (definingDependency, requirements) in requirements.lookupTable {
            for (requiredDependency, requiredVersion) in requirements {
                var requirements = invertedRequirements[requiredDependency] ?? [:]

                if requirements[definingDependency] != nil {
                    return .init(error: .duplicateDependencies([DuplicateDependency(dependency: requiredDependency, locations: [])]))
                }

                requirements[definingDependency] = requiredVersion
                invertedRequirements[requiredDependency] = requirements
            }
        }
        return .init(invertedRequirements)
    }

    /// Constructs CompatibilityInfo objects for dependencies with incompatibilities
    /// given a dictionary of dependencies with pinned versions and their corresponding requirements
    public static func incompatibilities(for dependencies: [Dependency: PinnedVersion], requirements: CompatibilityInfo.Requirements, projectDependencyRetriever: DependencyRetrieverProtocol) -> Result<[CompatibilityInfo], CarthageError> {
        return CompatibilityInfo.invert(requirements: requirements)
            .map { invertedRequirements -> [CompatibilityInfo] in
                return dependencies.compactMap { dependency, version in
                    if version.isSemantic, let requirements = invertedRequirements[dependency] {
                        return CompatibilityInfo(dependency: dependency, pinnedVersion: version, requirements: requirements, projectDependencyRetriever: projectDependencyRetriever)
                    }
                    return nil
                    }
                    .filter { !$0.incompatibleRequirements.isEmpty }
        }
    }
}
