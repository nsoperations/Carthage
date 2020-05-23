// swiftlint:disable file_length

import Foundation
import Result
import ReactiveSwift
import Tentacle
import XCDBLD
import ReactiveTask

/// Describes an event occurring to or with a project.
public enum ProjectEvent {
    /// The project is beginning to clone.
    case cloning(Dependency)

    /// The project is beginning a fetch.
    case fetching(Dependency)

    /// The project is being checked out to the specified revision.
    case checkingOut(Dependency, String)

    /// The project is downloading a binary-only framework definition.
    case downloadingBinaryFrameworkDefinition(Dependency, URL)

    /// Any available binaries for the specified release of the project are
    /// being downloaded. This may still be followed by `CheckingOut` event if
    /// there weren't any viable binaries after all.
    case downloadingBinaries(Dependency, String)

    /// Storig binaries to local cache
    case storingBinaries(Dependency, String)

    /// Installing binaries from local cache
    case installingBinaries(Dependency, String)

    /// Downloading any available binaries of the project is being skipped,
    /// because of a GitHub API request failure which is due to authentication
    /// or rate-limiting.
    case skippedDownloadingBinaries(Dependency, String)

    /// Installing of a binary framework is being skipped because of an inability
    /// to verify that it was built with a compatible Swift version.
    case skippedInstallingBinaries(dependency: Dependency, error: Error?)

    /// Building the project is being skipped, since the project is not sharing
    /// any framework schemes.
    case skippedBuilding(Dependency, String)

    /// Building the project is being skipped because it is cached.
    case skippedBuildingCached(Dependency)

    /// Rebuilding a cached project because of a version file/framework mismatch.
    case rebuildingCached(Dependency, VersionStatus)

    /// Building an uncached project.
    case buildingUncached(Dependency)

    /// Rebuilding because the installed binary is not valid
    case rebuildingBinary(Dependency, VersionStatus)

    /// Waiting for a lock on the specified URL.
    case waiting(URL)
    
    /// Generic warning message
    case warning(String)
    
    case crossReferencingSymbols
}

extension ProjectEvent: Equatable {
    public static func == (lhs: ProjectEvent, rhs: ProjectEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.cloning(left), .cloning(right)):
            return left == right

        case let (.fetching(left), .fetching(right)):
            return left == right

        case let (.checkingOut(leftIdentifier, leftRevision), .checkingOut(rightIdentifier, rightRevision)):
            return leftIdentifier == rightIdentifier && leftRevision == rightRevision

        case let (.downloadingBinaryFrameworkDefinition(leftIdentifier, leftURL), .downloadingBinaryFrameworkDefinition(rightIdentifier, rightURL)):
            return leftIdentifier == rightIdentifier && leftURL == rightURL

        case let (.downloadingBinaries(leftIdentifier, leftRevision), .downloadingBinaries(rightIdentifier, rightRevision)):
            return leftIdentifier == rightIdentifier && leftRevision == rightRevision

        case let (.skippedDownloadingBinaries(leftIdentifier, leftRevision), .skippedDownloadingBinaries(rightIdentifier, rightRevision)):
            return leftIdentifier == rightIdentifier && leftRevision == rightRevision

        case let (.skippedBuilding(leftIdentifier, leftRevision), .skippedBuilding(rightIdentifier, rightRevision)):
            return leftIdentifier == rightIdentifier && leftRevision == rightRevision

        case let (.waiting(left), .waiting(right)):
            return left == right
            
        case let (.warning(left), .warning(right)):
            return left == right
        
        case (.crossReferencingSymbols, .crossReferencingSymbols):
            return true

        default:
            return false
        }
    }
}

public typealias OutdatedDependency = (Dependency, PinnedVersion, PinnedVersion, PinnedVersion)

/// Represents a project that is using Carthage.
public final class Project { // swiftlint:disable:this type_body_length
    /// File URL to the root directory of the project.
    public let directoryURL: URL

    /// The file URL to the project's Cartfile.
    public var cartfileURL: URL {
        return Cartfile.url(in: directoryURL)
    }

    /// The file URL to the project's Cartfile.resolved.
    public var resolvedCartfileURL: URL {
        return ResolvedCartfile.url(in: directoryURL)
    }

    /// Whether to prefer HTTPS for cloning (vs. SSH).
    public var preferHTTPS: Bool {
        set {
            self.dependencyRetriever.preferHTTPS = newValue
        }

        get {
            return self.dependencyRetriever.preferHTTPS
        }
    }

    /// Timeout for waiting for a lock on the checkout cache for git operations (in case of concurrent usage of different carthage commands)
    public var lockTimeout: Int? {
        set {
            self.dependencyRetriever.lockTimeout = newValue
        }

        get {
            return self.dependencyRetriever.lockTimeout
        }
    }

    /// Whether to use submodules for dependencies, or just check out their
    /// working directories.
    public var useSubmodules: Bool {
        set {
            self.dependencyRetriever.useSubmodules = newValue
        }

        get {
            return self.dependencyRetriever.useSubmodules
        }
    }

    /// Sends each event that occurs to a project underneath the receiver (or
    /// the receiver itself).
    public let projectEvents: Signal<ProjectEvent, NoError>
    private let projectEventsObserver: Signal<ProjectEvent, NoError>.Observer

    let dependencyRetriever: ProjectDependencyRetriever
    
    private let cachedResolvedCartfile = Atomic<ResolvedCartfile?>(nil)
    
    private let verifyResolvedHash: Bool

    // MARK: - Public

    public init(directoryURL: URL, useNetrc: Bool = false, verifyResolvedHash: Bool = false) {
        precondition(directoryURL.isFileURL)

        let (signal, observer) = Signal<ProjectEvent, NoError>.pipe()
        projectEvents = signal
        projectEventsObserver = observer

        self.directoryURL = directoryURL
        self.verifyResolvedHash = verifyResolvedHash

        self.dependencyRetriever = ProjectDependencyRetriever(directoryURL: directoryURL, projectEventsObserver: projectEventsObserver)

        if useNetrc {
            self.dependencyRetriever.netrc = try? Netrc.load().get()
        }

        URLLock.globalWaitHandler = { urlLock in
            observer.send(value: .waiting(urlLock.url))
        }
    }

    /// Updates the dependencies of the project to the latest version. The
    /// changes will be reflected in Cartfile.resolved, and also in the working
    /// directory checkouts if the given parameter is true.
    public func updateDependencies(
        shouldCheckout: Bool = true,
        buildOptions: BuildOptions,
        dependenciesToUpdate: [String]? = nil,
        resolverEventObserver: ((ResolverEvent) -> Void)? = nil,
        dependencyRetriever: DependencyRetrieverProtocol? = nil
        ) -> SignalProducer<(), CarthageError> {
        let resolver = BackTrackingResolver(projectDependencyRetriever: dependencyRetriever ?? self.dependencyRetriever)
        if let eventObserver = resolverEventObserver {
            resolver.events.observeValues(eventObserver)
        }

        let dependenciesProducer = self.loadCombinedCartfile().map { Array($0.dependencies.keys) }

        return self.checkDependencies(dependenciesProducer: dependenciesProducer, dependenciesToCheck: dependenciesToUpdate)
            .then(
                self.updatedResolvedCartfile(dependenciesToUpdate, resolver: resolver)
                    .attemptMap { resolvedCartfile -> Result<(), CarthageError> in
                        return self.writeResolvedCartfile(resolvedCartfile)
                }
            )
            .then(shouldCheckout ? self.checkoutResolvedDependencies(dependenciesToUpdate, buildOptions: buildOptions) : .empty)
    }

    /// Checks out the dependencies listed in the project's Cartfile.resolved,
    /// optionally they are limited by the given list of dependency names.
    public func checkoutResolvedDependencies(_ dependenciesToCheckout: [String]? = nil, buildOptions: BuildOptions?) -> SignalProducer<(), CarthageError> {
        /// Determine whether the repository currently holds any submodules (if
        /// it even is a repository).
        let submodulesSignal = Git.submodulesInRepository(self.directoryURL)
            .reduce(into: [:]) { (submodulesByPath: inout [String: Submodule], submodule) in
                submodulesByPath[submodule.path] = submodule
        }

        let dependenciesProducer = self.loadResolvedCartfile(useCache: true).map { Array($0.dependencies.keys) }

        // List all the directories in the checkout dir

        var cartfile: ResolvedCartfile!

        return self.checkDependencies(dependenciesProducer: dependenciesProducer, dependenciesToCheck: dependenciesToCheckout)
            .then(self.loadResolvedCartfile(useCache: true)
                .flatMap(.latest) { resolvedCartfile -> SignalProducer<(Set<String>?, ResolvedCartfile), CarthageError> in
                    cartfile = resolvedCartfile
                    guard let dependenciesToCheckout = dependenciesToCheckout else {
                        return SignalProducer(value: (nil, resolvedCartfile))
                    }

                    return self.dependencyRetriever
                        .transitiveDependencies(resolvedCartfile: resolvedCartfile, includedDependencyNames: dependenciesToCheckout)
                        .map { (Set(dependenciesToCheckout + $0), resolvedCartfile) }
                }
                .map { dependenciesToCheckout, resolvedCartfile -> [(Dependency, PinnedVersion)] in
                    return resolvedCartfile.dependencies
                        .filter { dep, _ in dependenciesToCheckout?.contains(dep.name) ?? true }
                }
                .zip(with: submodulesSignal)
                .flatMap(.merge) { dependencies, submodulesByPath -> SignalProducer<(), CarthageError> in
                    return SignalProducer<(Dependency, PinnedVersion), CarthageError>(dependencies)
                        .flatMap(.concurrent(limit: Constants.concurrencyLimit)) { dependency, version -> SignalProducer<(Dependency, PinnedVersion), CarthageError> in
                            switch dependency {
                            case .git, .gitHub:
                                return self.dependencyRetriever.checkoutOrCloneDependency(dependency, version: version, submodulesByPath: submodulesByPath, resolvedCartfile: cartfile)
                                    .then(SignalProducer(value: (dependency, version)))
                            case .binary:
                                return .empty
                            }
                        }
                        .collect()
                        .flatMap(.concat) { pinnedDependencies -> SignalProducer<(Dependency, PinnedVersion), CarthageError> in
                            let dependencyNames = pinnedDependencies.map { $0.0.name }
                            return self.buildOrderForResolvedCartfile(cartfile, dependenciesToInclude: dependencyNames).map {
                                return ($0.0, $0.1)
                            }
                        }
                        .flatMap(.concat) { dependency, version -> SignalProducer<(), CarthageError> in
                            switch dependency {
                            case .git, .gitHub:
                                // symlink the checkout paths for checked-out dependencies
                                return self.symlinkCheckoutPaths(for: dependency, version: version, resolvedCartfile: cartfile)
                            case .binary:
                                return .empty
                            }
                        }
            })
            .then(self.removeNonExistingDependencyDirectories())
            .then(self.writeCartfileResolvedHash())
            .then(SignalProducer<(), CarthageError>.empty)
    }

    public func build(includingSelf: Bool, dependenciesToBuild: [String]?, buildOptions: BuildOptions, customProjectName: String?, customCommitish: String?) -> BuildSchemeProducer {
        let buildProducer = self.loadResolvedCartfile(useCache: true)
            .map { _ in self }
            .flatMapError { error -> SignalProducer<Project, CarthageError> in
                if !includingSelf {
                    return SignalProducer(error: error)
                } else {
                    // Ignore Cartfile.resolved loading failure. Assume the user
                    // just wants to build the enclosing project.
                    return .empty
                }
            }
            .flatMap(.merge) { _ in
                return self.buildCheckedOutDependenciesWithOptions(buildOptions, dependenciesToBuild: dependenciesToBuild)
        }

        if !includingSelf {
            return buildProducer
        } else {
            let currentProducers = self.loadResolvedCartfile(useCache: true)
                .map { resolvedCartfile -> Set<PinnedDependency> in
                    return resolvedCartfile.resolvedDependenciesSet()
                }
                .flatMapError { error -> SignalProducer<Set<PinnedDependency>, CarthageError> in
                    if (!self.resolvedCartfileURL.isExistingFile) {
                        return SignalProducer(value: Set())
                    } else {
                        return SignalProducer(error: error)
                    }
                }
                .flatMap(.concat) { resolvedDependencySet -> BuildSchemeProducer in
                    Xcode.buildInDirectory(self.directoryURL,
                                           withOptions: buildOptions,
                                           rootDirectoryURL: self.directoryURL,
                                           resolvedDependencySet: resolvedDependencySet,
                                           lockTimeout: self.lockTimeout,
                                           customProjectName: customProjectName,
                                           customCommitish: customCommitish)
                        .flatMapError { error -> BuildSchemeProducer in
                            switch error {
                            case let .noSharedFrameworkSchemes(project, _):
                                // Log that building the current project is being skipped.
                                self.projectEventsObserver.send(value: .skippedBuilding(project, error.description))
                                return .empty

                            default:
                                return SignalProducer(error: error)
                            }
                    }
                }
            return buildProducer.concat(currentProducers)
        }
    }

    /// Attempts to determine which of the project's Carthage
    /// dependencies are out of date.
    ///
    /// This will fetch dependency repositories as necessary, but will not check
    /// them out into the project's working directory.
    public func outdatedDependencies(_ includeNestedDependencies: Bool,
                                     resolver: ResolverProtocol? = nil,
                                     resolverEventObserver: ((ResolverEvent) -> Void)? = nil) -> SignalProducer<[OutdatedDependency], CarthageError> {
        let resolverClass = BackTrackingResolver.self
        let resolver = resolver ?? resolverClass.init(projectDependencyRetriever: OutdatedDependencyRetriever(impl: self.dependencyRetriever, includeNested: includeNestedDependencies))

        if let eventObserver = resolverEventObserver {
            resolver.events.observeValues(eventObserver)
        }

        let outdatedDependencies = SignalProducer
            .combineLatest(
                loadResolvedCartfile(useCache: true),
                updatedResolvedCartfile(resolver: resolver),
                latestDependencies(resolver: resolver)
            )
            .map { ($0.dependencies, $1.dependencies, $2) }
            .map { currentDependencies, updatedDependencies, latestDependencies -> [OutdatedDependency] in
                return updatedDependencies.compactMap { project, version -> OutdatedDependency? in
                    if let resolved = currentDependencies[project], let latest = latestDependencies[project], resolved != version || resolved != latest {
                        if resolved.semanticVersion == nil, version == resolved {
                            // If resolved version is not a semantic version but a commit
                            // it is a false-positive if `version` and `resolved` are the same
                            return nil
                        }

                        return (project, resolved, version, latest)
                    } else {
                        return nil
                    }
                }
        }

        if includeNestedDependencies {
            return outdatedDependencies
        }

        return SignalProducer
            .combineLatest(
                outdatedDependencies,
                loadCombinedCartfile()
            )
            .map { oudatedDependencies, combinedCartfile -> [OutdatedDependency] in
                return oudatedDependencies.filter { project, _, _, _ in
                    return combinedCartfile.dependencies[project] != nil
                }
        }
    }

    public func validate(dependencyRetriever: DependencyRetrieverProtocol? = nil) -> SignalProducer<(), CarthageError> {

        return SignalProducer
            .combineLatest(loadCombinedCartfile(), loadResolvedCartfile(useCache: true))
            .flatMap(.merge) { cartfile, resolvedCartfile in
                return self.validate(cartfile: cartfile, resolvedCartfile: resolvedCartfile, dependencyRetriever: dependencyRetriever)
            }
    }

    /// Stores all possible dependencies and versions of those dependencies in the specified local dependency store.
    ///
    /// If ignoreErrors is true, failure for retrieving some of the transitive dependencies or their versions will not be fatal,
    /// rather an empty collection is assumed.
    ///
    /// Dependency mappings are used to anonymize dependencies to avoid disclosure of possible sensitive information.
    /// Use key=source dependency and value=target dependency
    ///
    /// Specify an event observer to be notified by events of the DependencyCrawler.
    ///
    /// Upon success this method returns the mapped Cartfile and optionally ResolvedCartfile.
    public func storeDependencies(to store: LocalDependencyStore,
                                  ignoreErrors: Bool = false,
                                  dependencyMappings: [Dependency: Dependency]? = nil,
                                  eventObserver: ((ResolverEvent) -> Void)? = nil) -> SignalProducer<(Cartfile, ResolvedCartfile?), CarthageError> {
        let crawler = DependencyCrawler(
            dependencyRetriever: dependencyRetriever,
            store: store,
            mappings: dependencyMappings,
            ignoreErrors: ignoreErrors
        )

        if let observer = eventObserver {
            crawler.events.observeValues(observer)
        }

        let resolvedCartfile: SignalProducer<ResolvedCartfile?, CarthageError> = loadResolvedCartfile(useCache: true)
            .map(Optional.init)
            .flatMapError { _ in .init(value: nil) }

        return SignalProducer
            .zip(loadCombinedCartfile(), resolvedCartfile)
            .flatMap(.merge) { cartfile, resolvedCartfile -> SignalProducer<(Cartfile, ResolvedCartfile?), CarthageError> in
                let result = crawler.traverse(dependencies: cartfile.dependencies)

                if case .failure(let carthageError) = result {
                    return SignalProducer(error: carthageError)
                }

                let mappedDependencies: [Dependency: VersionSpecifier] = Dictionary(uniqueKeysWithValues: cartfile.dependencies.map { dependency, versionSpecifier -> (Dependency, VersionSpecifier) in
                    let mappedDependency = dependencyMappings?[dependency] ?? dependency
                    return (mappedDependency, versionSpecifier)
                })

                let mappedResolvedDependencies: [Dependency: PinnedVersion]? = resolvedCartfile.map {
                    Dictionary(uniqueKeysWithValues: $0.dependencies.map { dependency, pinnedVersion -> (Dependency, PinnedVersion) in
                        let mappedDependency = dependencyMappings?[dependency] ?? dependency
                        return (mappedDependency, pinnedVersion)
                    })
                }

                let mappedCartfile = Cartfile(dependencies: mappedDependencies)
                let mappedResolvedCartfile = mappedResolvedDependencies.map { ResolvedCartfile(dependencies: $0) }
                return SignalProducer(value: (mappedCartfile, mappedResolvedCartfile))
        }
    }

    // MARK: - Internal

    /// Attempts to load Cartfile or Cartfile.private from the given directory,
    /// merging their dependencies.
    func loadCombinedCartfile() -> SignalProducer<Cartfile, CarthageError> {
        let cartfileURL = directoryURL.appendingPathComponent(Constants.Project.cartfilePath, isDirectory: false)
        let privateCartfileURL = directoryURL.appendingPathComponent(Constants.Project.privateCartfilePath, isDirectory: false)

        func isNoSuchFileError(_ error: CarthageError) -> Bool {
            switch error {
            case let .readFailed(_, underlyingError):
                if let underlyingError = underlyingError {
                    return underlyingError.domain == NSCocoaErrorDomain && underlyingError.code == NSFileReadNoSuchFileError
                } else {
                    return false
                }

            default:
                return false
            }
        }

        let cartfile = SignalProducer { Cartfile.from(fileURL: cartfileURL) }
            .flatMapError { error -> SignalProducer<Cartfile, CarthageError> in
                if isNoSuchFileError(error) && FileManager.default.fileExists(atPath: privateCartfileURL.path) {
                    return SignalProducer(value: Cartfile())
                }

                return SignalProducer(error: error)
        }

        let privateCartfile = SignalProducer { Cartfile.from(fileURL: privateCartfileURL) }
            .flatMapError { error -> SignalProducer<Cartfile, CarthageError> in
                if isNoSuchFileError(error) {
                    return SignalProducer(value: Cartfile())
                }

                return SignalProducer(error: error)
        }

        return SignalProducer.zip(cartfile, privateCartfile)
            .attemptMap { cartfile, privateCartfile -> Result<Cartfile, CarthageError> in
                var cartfile = cartfile

                let duplicateDeps = cartfile.duplicateDependencies(from: privateCartfile).map { dependency in
                    return DuplicateDependency(
                        dependency: dependency,
                        locations: ["\(Constants.Project.cartfilePath)", "\(Constants.Project.privateCartfilePath)"]
                    )
                }

                if duplicateDeps.isEmpty {
                    cartfile.append(privateCartfile)
                    return .success(cartfile)
                }

                return .failure(.duplicateDependencies(duplicateDeps))
        }
    }

    /// Determines whether the requirements specified in this project's Cartfile.resolved
    /// are compatible with the versions specified in the Cartfile for each of those projects.
    ///
    /// Either emits a value to indicate success or an error.
    func validate(cartfile: Cartfile, resolvedCartfile: ResolvedCartfile, dependencyRetriever: DependencyRetrieverProtocol? = nil) -> SignalProducer<(), CarthageError> {

        let effectiveDependencyRetriever: DependencyRetrieverProtocol = dependencyRetriever ?? self.dependencyRetriever

        return SignalProducer(value: resolvedCartfile)
            .flatMap(.concat) { (resolved: ResolvedCartfile) -> SignalProducer<([Dependency: PinnedVersion], CompatibilityInfo.Requirements), CarthageError> in
                let requirements = self.requirementsByDependency(cartfile: cartfile, resolvedCartfile: resolved, tryCheckoutDirectory: false, dependencyRetriever: effectiveDependencyRetriever)
                return SignalProducer.zip(SignalProducer(value: resolved.dependencies), requirements)
            }
            .flatMap(.concat) { (info: ([Dependency: PinnedVersion], CompatibilityInfo.Requirements)) -> SignalProducer<[CompatibilityInfo], CarthageError> in
                let (dependencies, requirements) = info
                return .init(result: CompatibilityInfo.incompatibilities(for: dependencies, requirements: requirements, projectDependencyRetriever: effectiveDependencyRetriever))
            }
            .flatMap(.concat) { incompatibilities -> SignalProducer<(), CarthageError> in
                return incompatibilities.isEmpty ? .init(value: ()) : .init(error: .invalidResolvedCartfile(incompatibilities))
        }
    }
    
    public func hashForResolvedDependencies() -> SignalProducer<String, CarthageError> {
        return self.loadResolvedCartfile().map { cartfile in
            return Frameworks.hashForResolvedDependencySet(cartfile.resolvedDependenciesSet())
        }
    }

    /// Reads the project's Cartfile.resolved.
    func loadResolvedCartfile(useCache: Bool = false) -> SignalProducer<ResolvedCartfile, CarthageError> {
        if useCache, let cached = cachedResolvedCartfile.value {
            return SignalProducer(value: cached)
        }
        return SignalProducer {
            Result(catching: { try String(contentsOf: self.resolvedCartfileURL, encoding: .utf8) })
                .mapError { .readFailed(self.resolvedCartfileURL, $0) }
                .flatMap(ResolvedCartfile.from)
                .map { resolvedCartfile -> ResolvedCartfile in
                    self.cachedResolvedCartfile.value = resolvedCartfile
                    return resolvedCartfile
                }
        }
    }

    /// Writes the given Cartfile.resolved out to the project's directory.
    func writeResolvedCartfile(_ resolvedCartfile: ResolvedCartfile) -> Result<(), CarthageError> {
        return Result(at: resolvedCartfileURL, attempt: {
            do {
                self.cachedResolvedCartfile.value = nil
                try resolvedCartfile.description.write(to: $0, atomically: true, encoding: .utf8)
            } catch {
                throw CarthageError.writeFailed($0, error as NSError)
            }
        })
    }

    /// Finds the required dependencies and their corresponding version specifiers for each dependency in Cartfile.resolved.
    func requirementsByDependency(
        cartfile: Cartfile? = nil,
        resolvedCartfile: ResolvedCartfile,
        tryCheckoutDirectory: Bool,
        dependencyRetriever: DependencyRetrieverProtocol? = nil
        ) -> SignalProducer<CompatibilityInfo.Requirements, CarthageError> {

        let effectiveDependencyRetriever = dependencyRetriever ?? self.dependencyRetriever

        return SignalProducer(resolvedCartfile.dependencies)
            .flatMap(.concurrent(limit: Constants.concurrencyLimit)) { arg -> SignalProducer<(Dependency, (Dependency, VersionSpecifier)), CarthageError> in
                let (dependency, pinnedVersion) = arg
                return effectiveDependencyRetriever.dependencies(for: dependency, version: pinnedVersion, tryCheckoutDirectory: tryCheckoutDirectory)
                    .map { (dependency, $0) }
            }
            .collect()
            .flatMap(.merge) { dependencyAndRequirements -> SignalProducer<CompatibilityInfo.Requirements, CarthageError> in
                var requirements = CompatibilityInfo.Requirements()

                // Dependencies from Cartfile
                if let cartfile = cartfile {
                    for requirement in cartfile.dependencies {
                        let (requiredDependency, _) = requirement
                        if requirements.hasRequirement(for: requiredDependency, from: nil) {
                            return SignalProducer(error: .duplicateDependencies([DuplicateDependency(dependency: requiredDependency, locations: [])]))
                        }
                        requirements.setRequirement(requirement, from: nil)
                    }
                }

                // Dependencies from Cartfile.resolved
                for (dependency, requirement) in dependencyAndRequirements {
                    let (requiredDependency, _) = requirement
                    if requirements.hasRequirement(for: requiredDependency, from: dependency) {
                        return SignalProducer(error: .duplicateDependencies([DuplicateDependency(dependency: requiredDependency, locations: [])]))
                    }
                    requirements.setRequirement(requirement, from: dependency)
                }
                return SignalProducer(value: requirements)
        }
    }

    /// Attempts to determine the latest satisfiable version of the project's
    /// Carthage dependencies.
    ///
    /// This will fetch dependency repositories as necessary, but will not check
    /// them out into the project's working directory.
    func updatedResolvedCartfile(_ dependenciesToUpdate: [String]? = nil, resolver: ResolverProtocol) -> SignalProducer<ResolvedCartfile, CarthageError> {
        let resolvedCartfile: SignalProducer<ResolvedCartfile?, CarthageError> = loadResolvedCartfile(useCache: true)
            .map(Optional.init)
            .flatMapError { _ in .init(value: nil) }

        return SignalProducer
            .zip(loadCombinedCartfile(), resolvedCartfile)
            .flatMap(.merge) { cartfile, resolvedCartfile -> SignalProducer<[Dependency: PinnedVersion], CarthageError> in
                return resolver.resolve(
                    dependencies: cartfile.dependencies,
                    lastResolved: resolvedCartfile?.dependencies,
                    dependenciesToUpdate: dependenciesToUpdate
                )
            }
            .map(ResolvedCartfile.init)
    }

    func buildOrderForResolvedCartfile(
        _ cartfile: ResolvedCartfile,
        dependenciesToInclude: [String]? = nil
        ) -> SignalProducer<(Dependency, PinnedVersion, Int), CarthageError> {
        // swiftlint:disable:next nesting
        typealias DependencyGraph = [Dependency: Set<Dependency>]

        // A resolved cartfile already has all the recursive dependencies. All we need to do is sort
        // out the relationships between them. Loading the cartfile will each will give us its
        // dependencies. Building a recursive lookup table with this information will let us sort
        // dependencies before the projects that depend on them.
        return SignalProducer<(Dependency, PinnedVersion), CarthageError>(cartfile.dependencies.map { ($0, $1) })
            .flatMap(.merge) { (arg: (Dependency, PinnedVersion)) -> SignalProducer<DependencyGraph, CarthageError> in
                // Added mapping from name -> Dependency based on the ResolvedCartfile because
                // duplicate dependencies with the same name (e.g. github forks) should resolve to the same dependency.
                let (dependency, version) = arg
                return self.dependencyRetriever.dependencySet(for: dependency, version: version, resolvedCartfile: cartfile)
                    .map { dependencies in
                        [dependency: dependencies]
                }
            }
            .reduce(into: [:]) { (working: inout DependencyGraph, next: DependencyGraph) in
                for (key, value) in next {
                    working.updateValue(value, forKey: key)
                }
            }
            .flatMap(.latest) { (graph: DependencyGraph) -> SignalProducer<(Dependency, PinnedVersion, Int), CarthageError> in
                var filteredDependencies: Set<Dependency>?
                if let dependenciesToInclude = dependenciesToInclude {
                    filteredDependencies = Set(graph
                        .map { dependency, _ in dependency }
                        .filter { dependency in dependenciesToInclude.contains(dependency.name) })
                }

                let sortedDependencies: [NodeLevel<Dependency>]
                switch Algorithms.topologicalSortWithLevel(graph, nodes: filteredDependencies) {
                case let .failure(error):
                    switch error {
                    case let .cycle(nodes):
                        return SignalProducer(error: .dependencyCycle(nodes))
                    case let .missing(node):
                        return SignalProducer(error: .unknownDependencies([node.name]))
                    }
                case let .success(deps):
                    sortedDependencies = deps
                }
                
                let sortedPinnedDependencies: [(Dependency, PinnedVersion, Int)] = sortedDependencies.reduce(into: []) { array, level in
                    if let pinnedVersion = cartfile.dependencies[level.node] {
                        array.append((level.node, pinnedVersion, level.level))
                    }
                }
                return SignalProducer(sortedPinnedDependencies)
        }
    }

    /// Attempts to build each Carthage dependency that has been checked out,
    /// optionally they are limited by the given list of dependency names.
    /// Cached dependencies whose dependency trees are also cached will not
    /// be rebuilt unless otherwise specified via build options.
    ///
    /// Returns a producer-of-producers representing each scheme being built.
    func buildCheckedOutDependenciesWithOptions( // swiftlint:disable:this cyclomatic_complexity function_body_length
        _ options: BuildOptions,
        dependenciesToBuild: [String]? = nil,
        sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) }
        ) -> BuildSchemeProducer {

        var cartfile: ResolvedCartfile!
        var levelLookupDict = [Dependency: Int]()
        
        let build = loadResolvedCartfile(useCache: true)
            .flatMap(.concat) { resolvedCartfile -> SignalProducer<(Dependency, PinnedVersion), CarthageError> in
                cartfile = resolvedCartfile
                return self.buildOrderForResolvedCartfile(resolvedCartfile, dependenciesToInclude: dependenciesToBuild).map { entry in
                    levelLookupDict[entry.0] = entry.2
                    return (entry.0, entry.1)
                }
            }
            .flatMap(.concat) { dependency, pinnedVersion -> SignalProducer<(Dependency, PinnedVersion, Set<PinnedDependency>), CarthageError> in
                return self.dependencyRetriever.resolvedRecursiveDependencySet(for: dependency, version: pinnedVersion, resolvedCartfile: cartfile)
                    .map { set -> (Dependency, PinnedVersion, Set<PinnedDependency>) in
                        return (dependency, pinnedVersion, set)
                    }
            }
            .flatMap(.concurrent(limit: Constants.concurrencyLimit)) { dependency, version, resolvedDependencySet -> SignalProducer<((Dependency, PinnedVersion, Set<PinnedDependency>), Set<Dependency>, VersionStatus), CarthageError> in
                return SignalProducer.combineLatest(
                    SignalProducer(value: (dependency, version, resolvedDependencySet)),
                    self.dependencyRetriever.dependencySet(for: dependency, version: version, resolvedCartfile: cartfile),
                    VersionFile.versionFileMatches(dependency,
                                                   version: version,
                                                   platforms: options.platforms,
                                                   configuration: options.configuration,
                                                   resolvedDependencySet: options.matchResolvedDependenciesHash ? resolvedDependencySet : nil,
                                                   rootDirectoryURL: self.directoryURL,
                                                   toolchain: options.toolchain,
                                                   checkSourceHash: options.trackLocalChanges)
                )
                .startOnQueue(globalConcurrentProducerQueue)
            }
            .reduce([]) { includedDependencies, nextGroup -> [(Dependency, PinnedVersion, Set<PinnedDependency>)] in
                let (nextDependency, projects, versionStatus) = nextGroup

                var dependenciesIncludingNext = includedDependencies
                dependenciesIncludingNext.append(nextDependency)

                let projectsToBeBuilt = Set(includedDependencies.map { $0.0 })

                guard options.cacheBuilds && projects.isDisjoint(with: projectsToBeBuilt) else {
                    return dependenciesIncludingNext
                }
                
                if versionStatus == .versionFileNotFound {
                    self.projectEventsObserver.send(value: .buildingUncached(nextDependency.0))
                    return dependenciesIncludingNext
                } else if versionStatus == .matching {
                    self.projectEventsObserver.send(value: .skippedBuildingCached(nextDependency.0))
                    return includedDependencies
                } else {
                    self.projectEventsObserver.send(value: .rebuildingCached(nextDependency.0, versionStatus))
                    return dependenciesIncludingNext
                }
            }
            .flatMap(.concat) { (dependencies: [(Dependency, PinnedVersion, Set<PinnedDependency>)]) -> SignalProducer<[(Dependency, PinnedVersion)], CarthageError> in
                return self.installBinaries(dependencies: dependencies, levelLookupDict: levelLookupDict, cartfile: cartfile, options: options)
            }
            .flatMap(.concat) { (sameLevelDependencies: [(Dependency, PinnedVersion)]) -> BuildSchemeProducer in
                return self.buildSameLevelDependencies(sameLevelDependencies: sameLevelDependencies, options: options, cartfile: cartfile, sdkFilter: sdkFilter)
            }
        
        return self.verifyCartfileResolvedHash().then(build)
    }

    // MARK: - Private
    
    private func installBinaries(dependencies: [(Dependency, PinnedVersion, Set<PinnedDependency>)], levelLookupDict: [Dependency: Int], cartfile: ResolvedCartfile, options: BuildOptions) -> SignalProducer<[(Dependency, PinnedVersion)], CarthageError> {
        
        return SignalProducer(dependencies)
            .flatMap(.concurrent(limit: Constants.concurrencyLimit)) { (dependency: Dependency, version: PinnedVersion, resolvedDependencySet: Set<PinnedDependency>) -> SignalProducer<(Dependency, PinnedVersion, Set<PinnedDependency>), CarthageError> in
            switch dependency {
            case .git, .gitHub:
                guard options.useBinaries else {
                    return .empty
                }
                return self.dependencyRetriever.installBinaries(for: dependency, pinnedVersion: version, configuration: options.configuration, resolvedDependencySet: resolvedDependencySet, strictMatch: options.matchResolvedDependenciesHash, platforms: options.platforms, toolchain: options.toolchain, customCacheCommand: options.customCacheCommand)
                    .filterMap { installed -> (Dependency, PinnedVersion, Set<PinnedDependency>)? in
                        return installed ? (dependency, version, resolvedDependencySet) : nil
                }
            case let .binary(binary):
                return self.dependencyRetriever.installBinariesForBinaryProject(binary: binary, pinnedVersion: version, configuration: options.configuration, resolvedDependencySet: resolvedDependencySet, strictMatch: options.matchResolvedDependenciesHash, platforms: options.platforms, toolchain: options.toolchain)
                    .then(.init(value: (dependency, version, resolvedDependencySet)))
            }
        }
        .flatMap(.merge) { dependency, version, resolvedDependencySet -> SignalProducer<(Dependency, PinnedVersion, Set<PinnedDependency>), CarthageError> in
            // Symlink the build folder of binary downloads for consistency with regular checkouts
            // (even though it's not necessary since binary downloads aren't built by Carthage)
            return self.symlinkBuildPathIfNeeded(for: dependency, version: version, resolvedCartfile: cartfile)
                .then(.init(value: (dependency, version, resolvedDependencySet)))
        }
        .collect()
        .flatMap(.concat) { dependencyVersions -> SignalProducer<(Dependency, PinnedVersion, Set<PinnedDependency>, [PlatformFramework: Set<String>]), CarthageError> in
            if !dependencyVersions.isEmpty {
                self.projectEventsObserver.send(value: .crossReferencingSymbols)
                // Add the symbols of the installed binaries to the externalSymbolsMap, after downloading
                let platforms: Set<Platform>? = options.platforms.isEmpty ? nil : options.platforms
                
                return Frameworks.definedSymbolsInBuildFolder(directoryURL: self.directoryURL, platforms: platforms)
                    .reduce(into: [:], { (map, entry) in
                        map[entry.0] = entry.1
                    })
                    .flatMap(.concat) { externalSymbolsMap -> SignalProducer<(Dependency, PinnedVersion, Set<PinnedDependency>, [PlatformFramework: Set<String>]), CarthageError> in
                        return SignalProducer(dependencyVersions).map { ($0, $1, $2, externalSymbolsMap) }
                    }
            }
            return SignalProducer(dependencyVersions).map { dependency, version, resolvedDependencySet in
                return (dependency, version, resolvedDependencySet, [:])
            }
        }
        .flatMap(.concurrent(limit: Constants.concurrencyLimit)) { dependency, version, resolvedDependencySet, externalSymbolsMap -> SignalProducer<(Dependency, PinnedVersion, VersionStatus), CarthageError> in
            return VersionFile.versionFileMatches(
                dependency,
                version: version,
                platforms: options.platforms,
                configuration: options.configuration,
                resolvedDependencySet: options.matchResolvedDependenciesHash ? resolvedDependencySet : nil,
                rootDirectoryURL: self.directoryURL,
                toolchain: options.toolchain,
                checkSourceHash: options.trackLocalChanges,
                externallyDefinedSymbols: externalSymbolsMap
                )
                .map { matches in return (dependency, version, matches) }
                .startOnQueue(globalConcurrentProducerQueue)
        }
        .filterMap { dependency, version, versionStatus -> (Dependency, PinnedVersion)? in
            guard versionStatus == .matching else {
                self.projectEventsObserver.send(value: .rebuildingBinary(dependency, versionStatus))
                return nil
            }
            return (dependency, version)
        }
        .collect()
        .map { installedDependencies -> [(Dependency, PinnedVersion)] in
            // Filters out dependencies that we've downloaded binaries for
            // but preserves the build order
            return dependencies.compactMap { dependency, pinnedVersion, resolvedDependencySet -> (Dependency, PinnedVersion)? in
                guard installedDependencies.contains(where: { $0.0 == dependency }) else {
                    return (dependency, pinnedVersion)
                }
                return nil
            }
        }
        .flatMap(.concat) { dependencies -> SignalProducer<[(Dependency, PinnedVersion)], CarthageError> in
            let maxLevel = levelLookupDict.values.max() ?? -1
            var leveledDependencies: [[(Dependency, PinnedVersion)]] = Array(repeating: [], count: maxLevel + 1)
            for versionedDependency in dependencies {
                if let level = levelLookupDict[versionedDependency.0] {
                    leveledDependencies[level].append(versionedDependency)
                } else {
                    return SignalProducer(error: CarthageError.internalError(description: "Could not find dependency \(versionedDependency.0) in build list"))
                }
            }
            return SignalProducer(leveledDependencies)
        }
    }
    
    private func removeNonExistingDependencyDirectories() -> SignalProducer<(), CarthageError> {
        return SignalProducer { () -> Result<(), CarthageError> in
            return Result<(), CarthageError>(catching: { () -> () in
                
                let resolvedCartfile = try self.loadResolvedCartfile(useCache: true).single()!.get()
                let foundDependencies = Set(resolvedCartfile.dependencies.keys.map { $0.name })
                
                let checkoutsFolder = self.directoryURL.appendingPathComponent(Constants.checkoutsPath)
                let urls: [URL]
                do {
                    if checkoutsFolder.isExistingDirectory {
                        urls = try FileManager.default.contentsOfDirectory(at: checkoutsFolder, includingPropertiesForKeys: nil, options: [])
                    } else {
                        urls = [URL]()
                    }
                } catch {
                    throw CarthageError.readFailed(checkoutsFolder, error as NSError)
                }
                for url in urls where !foundDependencies.contains(url.lastPathComponent) {
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        throw CarthageError.internalError(description: "Could not remove directory at URL: \(url)")
                    }
                }
            })
        }
    }
    
    private func writeCartfileResolvedHash() -> SignalProducer<(), CarthageError> {
        return SignalProducer { () -> Result<(), CarthageError> in
            return Result<(), CarthageError>(catching: { () -> () in
                
                let resolvedCartfile = try self.loadResolvedCartfile(useCache: true).single()!.get()
                let set = resolvedCartfile.resolvedDependenciesSet()
                let hash: String = Frameworks.hashForResolvedDependencySet(set)
                let fileURL: URL = self.directoryURL.appendingPathComponent(Constants.Project.resolvedCartfileHashPath)
                
                do {
                    let dirURL = fileURL.deletingLastPathComponent()
                    if !dirURL.isExistingDirectory {
                        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
                    }
                    try hash.write(to: fileURL, atomically: true, encoding: .utf8)
                } catch {
                    throw CarthageError.writeFailed(fileURL, error as NSError)
                }
            })
        }
    }
    
    private func verifyCartfileResolvedHash() -> SignalProducer<(), CarthageError> {
        return SignalProducer { () -> Result<(), CarthageError> in
            return Result<(), CarthageError>(catching: { () -> () in
                
                guard self.verifyResolvedHash else {
                    return
                }
                
                let resolvedCartfile = try self.loadResolvedCartfile(useCache: true).single()!.get()
                let set = resolvedCartfile.resolvedDependenciesSet()
                let hash: String = Frameworks.hashForResolvedDependencySet(set)
                let fileURL: URL = self.directoryURL.appendingPathComponent(Constants.Project.resolvedCartfileHashPath)
                
                if fileURL.isExistingFile {
                    let existingHash = try? String(contentsOf: fileURL)
                    if hash == existingHash {
                        return
                    }
                }
                throw CarthageError.bootstrapNeeded
            })
        }
    }

    private func buildSameLevelDependencies(sameLevelDependencies: [(Dependency, PinnedVersion)], options: BuildOptions, cartfile: ResolvedCartfile, sdkFilter: @escaping SDKFilterCallback) -> BuildSchemeProducer {
        
        let concurrencyLimit: UInt = min(max(1, UInt(sameLevelDependencies.count)), Constants.concurrencyLimit)
        let swiftVersion = SwiftToolchain.swiftVersion(usingToolchain: options.toolchain).first()!.value?.commitish ?? "Unknown"
        
        return SignalProducer(sameLevelDependencies)
            .flatMap(.concat) { dependency, version -> SignalProducer<(Dependency, PinnedVersion, Set<PinnedDependency>), CarthageError> in
                return self.dependencyRetriever.resolvedRecursiveDependencySet(for: dependency, version: version, resolvedCartfile: cartfile)
                    .map { set in
                        return (dependency, version, set)
                    }
            }
            .flatMap(.concurrent(limit: concurrencyLimit)) { dependency, version, resolvedDependencySet -> BuildSchemeProducer in
                let dependencyURL = self.directoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
                if !FileManager.default.fileExists(atPath: dependencyURL.path) {
                    self.projectEventsObserver.send(value: .warning("No checkout found for \(dependency.name), skipping build"))
                    return .empty
                }
                
                let projectCartfileURL = ProjectCartfile.url(in: dependencyURL)
                if !projectCartfileURL.isExistingFile {
                    self.projectEventsObserver.send(value: .warning("No \(Constants.Project.projectCartfilePath) found for \(dependency.name), generate one using `carthage generate-project-file` to decrease build time"))
                }

                var options = options
                let baseURL = URL(fileURLWithPath: options.derivedDataPath)
                let derivedDataPerSwiftVersion = baseURL.appendingPathComponent(swiftVersion, isDirectory: true)
                let derivedDataPerDependency = derivedDataPerSwiftVersion.appendingPathComponent(dependency.name, isDirectory: true)
                let derivedDataVersioned = derivedDataPerDependency.appendingPathComponent(version.commitish, isDirectory: true)
                let rootDirectoryURL = self.directoryURL
                options.derivedDataPath = derivedDataVersioned.resolvingSymlinksInPath().path

                let builtProductsHandler: (([URL]) -> SignalProducer<(), CarthageError>)? = (options.useBinaries) ? { builtProductURLs in
                    let frameworkNames = builtProductURLs.compactMap { url -> String? in
                        guard url.pathExtension == "framework" else {
                            return nil
                        }
                        return url.deletingPathExtension().lastPathComponent
                    }
                    return self.dependencyRetriever.storeBinaries(for: dependency, frameworkNames: frameworkNames, pinnedVersion: version, configuration: options.configuration, resolvedDependencySet: options.matchResolvedDependenciesHash ? resolvedDependencySet : nil, toolchain: options.toolchain).map { _ in }
                    } : nil

                return self.symlinkBuildPathIfNeeded(for: dependency, version: version, resolvedCartfile: cartfile)
                    .then(Xcode.build(dependency: dependency, version: version, rootDirectoryURL: rootDirectoryURL, withOptions: options, resolvedDependencySet: resolvedDependencySet, lockTimeout: self.lockTimeout, sdkFilter: sdkFilter, builtProductsHandler: builtProductsHandler))
                    .startOnQueue(globalConcurrentProducerQueue)
                    .flatMapError { error -> BuildSchemeProducer in
                        switch error {
                        case .noSharedFrameworkSchemes:
                            // Log that building the dependency is being skipped,
                            // not to error out with `.noSharedFrameworkSchemes`
                            // to continue building other dependencies.
                            self.projectEventsObserver.send(value: .skippedBuilding(dependency, error.description))

                            if options.cacheBuilds {
                                // Create a version file for a dependency with no shared schemes
                                // so that its cache is not always considered invalid.
                                return VersionFile.createVersionFileForCommitish(version.commitish,
                                                                                 dependencyName: dependency.name,
                                                                                 platforms: options.platforms,
                                                                                 configuration: options.configuration,
                                                                                 resolvedDependencySet: resolvedDependencySet,
                                                                                 buildProducts: [],
                                                                                 rootDirectoryURL: self.directoryURL)
                                    .then(BuildSchemeProducer.empty)
                            }
                            return .empty

                        default:
                            return SignalProducer(error: error)
                        }
            }
        }
    }
    
    private func checkDependencies(dependenciesProducer: SignalProducer<[Dependency], CarthageError>, dependenciesToCheck: [String]?) -> SignalProducer<(), CarthageError> {

        let checkDependencies: SignalProducer<(), CarthageError>
        if let dependenciesToCheck = dependenciesToCheck {
            checkDependencies = dependenciesProducer
                .flatMap(.concat) { dependencies -> SignalProducer<(), CarthageError> in
                    let dependencyNames = dependencies.map { $0.name.lowercased() }
                    let unknownDependencyNames = Set(dependenciesToCheck.map { $0.lowercased() }).subtracting(dependencyNames)

                    if !unknownDependencyNames.isEmpty {
                        return SignalProducer(error: .unknownDependencies(unknownDependencyNames.sorted()))
                    }
                    return .empty
            }
        } else {
            checkDependencies = .empty
        }

        return checkDependencies
    }

    private func symlinkBuildPathIfNeeded(for dependency: Dependency, version: PinnedVersion, resolvedCartfile: ResolvedCartfile) -> SignalProducer<(), CarthageError> {
        return dependencyRetriever.recursiveDependencySet(for: dependency, version: version, resolvedCartfile: resolvedCartfile)
            .flatMap(.merge) { dependencies -> SignalProducer<(), CarthageError> in
                // Don't symlink the build folder if the dependency doesn't have
                // any Carthage dependencies
                if dependencies.isEmpty {
                    return .empty
                }
                return Project.symlinkBuildPath(for: dependency, rootDirectoryURL: self.directoryURL)
        }
    }

    /// Creates symlink between the dependency build folder and the root build folder
    ///
    /// Returns a signal indicating success
    private static func symlinkBuildPath(for dependency: Dependency, rootDirectoryURL: URL) -> SignalProducer<(), CarthageError> {
        return SignalProducer { () -> Result<(), CarthageError> in
            let rootBinariesURL = rootDirectoryURL.appendingPathComponent(Constants.binariesFolderPath, isDirectory: true).resolvingSymlinksInPath()
            let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
            let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()
            let fileManager = FileManager.default

            // Link this dependency's Carthage/Build folder to that of the root
            // project, so it can see all products built already, and so we can
            // automatically drop this dependency's product in the right place.
            let dependencyBinariesURL = dependencyURL.appendingPathComponent(Constants.binariesFolderPath, isDirectory: true)

            let createDirectory = { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) }
            return Result(at: rootBinariesURL, attempt: createDirectory)
                .flatMap { _ in
                    Result(at: dependencyBinariesURL, attempt: fileManager.removeItem(at:))
                        .recover(with: Result(at: dependencyBinariesURL.deletingLastPathComponent(), attempt: createDirectory))
                }
                .flatMap { _ in
                    Result(at: rawDependencyURL, carthageError: CarthageError.readFailed, attempt: {
                        try $0.resourceValues(forKeys: [ .isSymbolicLinkKey ]).isSymbolicLink
                    })
                        .flatMap { isSymlink in
                            Result(at: dependencyBinariesURL, attempt: {
                                if isSymlink == true {
                                    return try fileManager.createSymbolicLink(at: $0, withDestinationURL: rootBinariesURL)
                                } else {
                                    let linkDestinationPath = Dependencies.relativeLinkDestination(for: dependency, subdirectory: Constants.binariesFolderPath)
                                    return try fileManager.createSymbolicLink(atPath: $0.path, withDestinationPath: linkDestinationPath)
                                }
                            })
                    }
            }
        }
    }
    
    /// Creates symlink between the dependency checkouts and the root checkouts
    private func symlinkCheckoutPaths(
        for dependency: Dependency,
        version: PinnedVersion,
        resolvedCartfile: ResolvedCartfile
        ) -> SignalProducer<(), CarthageError> {
        
        let rootDirectoryURL = self.directoryURL
        let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
        let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()
        let dependencyCheckoutsURL = dependencyURL.appendingPathComponent(Constants.checkoutsPath, isDirectory: true).resolvingSymlinksInPath()
        let repositoryURL = Dependencies.repositoryFileURL(for: dependency, baseURL: Constants.Dependency.repositoriesURL)
        let fileManager = FileManager.default

        return self.dependencyRetriever.recursiveDependencySet(for: dependency, version: version, resolvedCartfile: resolvedCartfile)
            // file system objects which might conflict with symlinks
            .zip(with: Git.list(treeish: version.commitish, atPath: Constants.checkoutsPath, inRepository: repositoryURL)
                .map { (path: String) in (path as NSString).lastPathComponent }
                .collect()
            )
            .attemptMap { (dependencies: Set<Dependency>, components: [String]) -> Result<(), CarthageError> in
                let names = dependencies
                    .filter { dependency in
                        // Filter out dependencies with names matching (case-insensitively) file system objects from git in `CarthageProjectCheckoutsPath`.
                        // Edge case warning on file system case-sensitivity. If a differently-cased file system object exists in git
                        // and is stored on a case-sensitive file system (like the Sierra preview of APFS), we currently preempt
                        // the non-conflicting symlink. Probably, nobody actually desires or needs the opposite behavior.
                        !components.contains {
                            dependency.name.caseInsensitiveCompare($0) == .orderedSame
                        }
                    }
                    .map { $0.name }

                // If no `CarthageProjectCheckoutsPath`-housed symlinks are needed,
                // return early after potentially adding submodules
                // (which could be outside `CarthageProjectCheckoutsPath`).
                if names.isEmpty { return .success(()) } // swiftlint:disable:this single_line_return

                do {
                    try fileManager.createDirectory(at: dependencyCheckoutsURL, withIntermediateDirectories: true)
                } catch let error as NSError {
                    if !(error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError) {
                        return .failure(.writeFailed(dependencyCheckoutsURL, error))
                    }
                }

                for name in names {
                    let dependencyCheckoutURL = dependencyCheckoutsURL.appendingPathComponent(name)
                    let subdirectoryPath = (Constants.checkoutsPath as NSString).appendingPathComponent(name)
                    let linkDestinationPath = Dependencies.relativeLinkDestination(for: dependency, subdirectory: subdirectoryPath)

                    let dependencyCheckoutURLResource = try? dependencyCheckoutURL.resourceValues(forKeys: [
                        .isSymbolicLinkKey,
                        .isDirectoryKey,
                        ])

                    if dependencyCheckoutURLResource?.isSymbolicLink == true {
                        _ = dependencyCheckoutURL.path.withCString(Darwin.unlink)
                    } else if dependencyCheckoutURLResource?.isDirectory == true {
                        // older version of carthage wrote this directory?
                        // user wrote this directory, unaware of the precedent not to circumvent carthage’s management?
                        // directory exists as the result of rogue process or gamma ray?

                        // swiftlint:disable:next todo
                        // TODO: explore possibility of messaging user, informing that deleting said directory will result
                        // in symlink creation with carthage versions greater than 0.20.0, maybe with more broad advice on
                        // “from scratch” reproducability.
                        continue
                    }

                    if let error = Result(at: dependencyCheckoutURL, attempt: {
                        try fileManager.createSymbolicLink(atPath: $0.path, withDestinationPath: linkDestinationPath)
                    }).error {
                        return .failure(error)
                    }
                }

                return .success(())
        }
    }

    /// Attempts to determine the latest version (whether satisfiable or not)
    /// of the project's Carthage dependencies.
    ///
    /// This will fetch dependency repositories as necessary, but will not check
    /// them out into the project's working directory.
    private func latestDependencies(resolver: ResolverProtocol) -> SignalProducer<[Dependency: PinnedVersion], CarthageError> {
        func resolve(prefersGitReference: Bool) -> SignalProducer<[Dependency: PinnedVersion], CarthageError> {
            return SignalProducer
                .combineLatest(loadCombinedCartfile(), loadResolvedCartfile(useCache: true))
                .map { cartfile, resolvedCartfile in
                    resolvedCartfile
                        .dependencies
                        .reduce(into: [Dependency: VersionSpecifier]()) { result, group in
                            let dependency = group.key
                            let specifier: VersionSpecifier
                            if case let .gitReference(value)? = cartfile.dependencies[dependency], prefersGitReference {
                                specifier = .gitReference(value)
                            } else {
                                specifier = .any
                            }
                            result[dependency] = specifier
                    }
                }
                .flatMap(.merge) { resolver.resolve(dependencies: $0, lastResolved: nil, dependenciesToUpdate: nil) }
        }

        return resolve(prefersGitReference: false).flatMapError { error in
            switch error {
            case .taggedVersionNotFound:
                return resolve(prefersGitReference: true)
            default:
                return SignalProducer(error: error)
            }
        }
    }
}

private class OutdatedDependencyRetriever: DependencyRetrieverProtocol {
    private let impl: ProjectDependencyRetriever
    private let includeNested: Bool

    init(impl: ProjectDependencyRetriever, includeNested: Bool) {
        self.impl = impl
        self.includeNested = includeNested
    }

    func dependencies(for dependency: Dependency, version: PinnedVersion, tryCheckoutDirectory: Bool) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
        guard includeNested else {
            return SignalProducer<(Dependency, VersionSpecifier), CarthageError>.empty
        }
        return impl.dependencies(for: dependency, version: version, tryCheckoutDirectory: tryCheckoutDirectory)
    }

    func resolvedGitReference(_ dependency: Dependency, reference: String) -> SignalProducer<PinnedVersion, CarthageError> {
        return impl.resolvedGitReference(dependency, reference: reference)
    }

    func versions(for dependency: Dependency) -> SignalProducer<PinnedVersion, CarthageError> {
        return impl.versions(for: dependency)
    }
}
