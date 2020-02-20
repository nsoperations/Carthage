import Foundation
import Result

/// Represents a parsed Cartfile.resolved, which specifies which exact version was
/// checked out for each dependency.
public struct ResolvedCartfile {
    /// The dependencies listed in the Cartfile.resolved.
    public let dependencies: [Dependency: PinnedVersion]
    private let dependenciesByName: [String: Dependency]

    public init(dependencies: [Dependency: PinnedVersion]) {
        self.dependencies = dependencies
        var dependenciesByName = [String: Dependency]()
        for (dependency, _) in dependencies {
            dependenciesByName[dependency.name] = dependency
        }
        self.dependenciesByName = dependenciesByName
    }

    public func dependency(for name: String) -> Dependency? {
        return dependenciesByName[name]
    }

    public func version(for name: String) -> PinnedVersion? {
        if let dependency = dependency(for: name) {
            return dependencies[dependency]
        } else {
            return nil
        }
    }
    
    public func resolvedDependenciesSet() -> Set<PinnedDependency> {
        return self.dependencies.reduce(into: Set<PinnedDependency>()) { set, entry in
            set.insert(PinnedDependency(dependency: entry.0, pinnedVersion: entry.1))
        }
    }
}

extension ResolvedCartfile: CartfileProtocol {
    public static var relativePath: String {
        return Constants.Project.resolvedCartfilePath
    }

    /// Attempts to parse Cartfile.resolved information from a string.
    public static func from(string: String) -> Result<ResolvedCartfile, CarthageError> {
        var dependencies = [Dependency: PinnedVersion]()
        var result: Result<(), CarthageError> = .success(())

        let scanner = Scanner(string: string)
        scannerLoop: while !scanner.isAtEnd {
            switch Dependency.from(scanner).fanout(PinnedVersion.from(scanner)) {
            case let .success((dep, version)):
                dependencies[dep] = version

            case let .failure(error):
                result = .failure(CarthageError(scannableError: error))
                break scannerLoop
            }
        }
        return result.map { _ in ResolvedCartfile(dependencies: dependencies) }
    }
}

extension ResolvedCartfile: CustomStringConvertible {
    public var description: String {
        return dependencies
            .sorted { $0.key.description < $1.key.description }
            .map { "\($0.key) \"\($0.value)\"" }
            .joined(separator: "\n")
            .appending("\n")
    }
}
