// swiftlint:disable file_length

import Foundation
import Result
import ReactiveSwift
import Tentacle
import XCDBLD
import ReactiveTask
import SPMUtility

import struct Foundation.URL
import enum XCDBLD.Platform

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

    /// Downloading any available binaries of the project is being skipped,
    /// because of a GitHub API request failure which is due to authentication
    /// or rate-limiting.
    case skippedDownloadingBinaries(Dependency, String)

    /// Installing of a binary framework is being skipped because of an inability
    /// to verify that it was built with a compatible Swift version.
    case skippedInstallingBinaries(dependency: Dependency, error: Error)

    /// Building the project is being skipped, since the project is not sharing
    /// any framework schemes.
    case skippedBuilding(Dependency, String)

    /// Building the project is being skipped because it is cached.
    case skippedBuildingCached(Dependency)

    /// Rebuilding a cached project because of a version file/framework mismatch.
    case rebuildingCached(Dependency)

    /// Building an uncached project.
    case buildingUncached(Dependency)
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

        default:
            return false
        }
    }
}

/// Represents a project that is using Carthage.
public final class Project { // swiftlint:disable:this type_body_length
    /// File URL to the root directory of the project.
    public let directoryURL: URL

    /// The file URL to the project's Cartfile.
    public var cartfileURL: URL {
        return directoryURL.appendingPathComponent(Constants.Project.cartfilePath, isDirectory: false)
    }

    /// The file URL to the project's Cartfile.resolved.
    public var resolvedCartfileURL: URL {
        return directoryURL.appendingPathComponent(Constants.Project.resolvedCartfilePath, isDirectory: false)
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
    public var lockTimeout: Int {
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

    public init(directoryURL: URL) {
        precondition(directoryURL.isFileURL)

        let (signal, observer) = Signal<ProjectEvent, NoError>.pipe()
        projectEvents = signal
        projectEventsObserver = observer

        self.directoryURL = directoryURL
        self.dependencyRetriever = ProjectDependencyRetriever(directoryURL: directoryURL, projectEventsObserver: projectEventsObserver)
    }

    private lazy var xcodeVersionDirectory: String = XcodeVersion.make()
        .map { "\($0.version)_\($0.buildVersion)" } ?? "Unknown"

    /// Attempts to load Cartfile or Cartfile.private from the given directory,
    /// merging their dependencies.
    public func loadCombinedCartfile() -> SignalProducer<Cartfile, CarthageError> {
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

        let cartfile = SignalProducer { Cartfile.from(file: cartfileURL) }
            .flatMapError { error -> SignalProducer<Cartfile, CarthageError> in
                if isNoSuchFileError(error) && FileManager.default.fileExists(atPath: privateCartfileURL.path) {
                    return SignalProducer(value: Cartfile())
                }

                return SignalProducer(error: error)
        }

        let privateCartfile = SignalProducer { Cartfile.from(file: privateCartfileURL) }
            .flatMapError { error -> SignalProducer<Cartfile, CarthageError> in
                if isNoSuchFileError(error) {
                    return SignalProducer(value: Cartfile())
                }

                return SignalProducer(error: error)
        }

        return SignalProducer.zip(cartfile, privateCartfile)
            .attemptMap { cartfile, privateCartfile -> Result<Cartfile, CarthageError> in
                var cartfile = cartfile

                let duplicateDeps = duplicateDependenciesIn(cartfile, privateCartfile).map { dependency in
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

    /// Reads the project's Cartfile.resolved.
    public func loadResolvedCartfile() -> SignalProducer<ResolvedCartfile, CarthageError> {
        return SignalProducer {
            Result(catching: { try String(contentsOf: self.resolvedCartfileURL, encoding: .utf8) })
                .mapError { .readFailed(self.resolvedCartfileURL, $0) }
                .flatMap(ResolvedCartfile.from)
        }
    }

    /// Writes the given Cartfile.resolved out to the project's directory.
    public func writeResolvedCartfile(_ resolvedCartfile: ResolvedCartfile) -> Result<(), CarthageError> {
        return Result(at: resolvedCartfileURL, attempt: {
            try resolvedCartfile.description.write(to: $0, atomically: true, encoding: .utf8)
        })
    }

    /// Finds the required dependencies and their corresponding version specifiers for each dependency in Cartfile.resolved.
    func requirementsByDependency(
        resolvedCartfile: ResolvedCartfile,
        tryCheckoutDirectory: Bool
        ) -> SignalProducer<CompatibilityInfo.Requirements, CarthageError> {
        return SignalProducer(resolvedCartfile.dependencies)
            .flatMap(.concurrent(limit: 4)) { arg -> SignalProducer<(Dependency, (Dependency, VersionSpecifier)), CarthageError> in
                let (dependency, pinnedVersion) = arg
                return self.dependencyRetriever.dependencies(for: dependency, version: pinnedVersion, tryCheckoutDirectory: tryCheckoutDirectory)
                    .map { (dependency, $0) }
            }
            .collect()
            .flatMap(.merge) { dependencyAndRequirements -> SignalProducer<CompatibilityInfo.Requirements, CarthageError> in
                var dict: CompatibilityInfo.Requirements = [:]
                for (dependency, requirement) in dependencyAndRequirements {
                    let (requiredDependency, requiredVersion) = requirement
                    var requirementsDict = dict[dependency] ?? [:]

                    if requirementsDict[requiredDependency] != nil {
                        return SignalProducer(error: .duplicateDependencies([DuplicateDependency(dependency: requiredDependency, locations: [])]))
                    }

                    requirementsDict[requiredDependency] = requiredVersion
                    dict[dependency] = requirementsDict
                }
                return SignalProducer(value: dict)
        }
    }

    /// Attempts to determine the latest satisfiable version of the project's
    /// Carthage dependencies.
    ///
    /// This will fetch dependency repositories as necessary, but will not check
    /// them out into the project's working directory.
    public func updatedResolvedCartfile(_ dependenciesToUpdate: [String]? = nil, resolver: ResolverProtocol) -> SignalProducer<ResolvedCartfile, CarthageError> {
        let resolvedCartfile: SignalProducer<ResolvedCartfile?, CarthageError> = loadResolvedCartfile()
            .map(Optional.init)
            .flatMapError { _ in .init(value: nil) }

        return SignalProducer
            .zip(loadCombinedCartfile(), resolvedCartfile)
            .flatMap(.merge) { cartfile, resolvedCartfile in
                return resolver.resolve(
                    dependencies: cartfile.dependencies,
                    lastResolved: resolvedCartfile?.dependencies,
                    dependenciesToUpdate: dependenciesToUpdate
                )
            }
            .map(ResolvedCartfile.init)
    }

    /// Attempts to determine the latest version (whether satisfiable or not)
    /// of the project's Carthage dependencies.
    ///
    /// This will fetch dependency repositories as necessary, but will not check
    /// them out into the project's working directory.
    private func latestDependencies(resolver: ResolverProtocol) -> SignalProducer<[Dependency: PinnedVersion], CarthageError> {
        func resolve(prefersGitReference: Bool) -> SignalProducer<[Dependency: PinnedVersion], CarthageError> {
            return SignalProducer
                .combineLatest(loadCombinedCartfile(), loadResolvedCartfile())
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

    public typealias OutdatedDependency = (Dependency, PinnedVersion, PinnedVersion, PinnedVersion)
    /// Attempts to determine which of the project's Carthage
    /// dependencies are out of date.
    ///
    /// This will fetch dependency repositories as necessary, but will not check
    /// them out into the project's working directory.
    public func outdatedDependencies(_ includeNestedDependencies: Bool, resolver: ResolverProtocol? = nil) -> SignalProducer<[OutdatedDependency], CarthageError> {
        let resolverClass = BackTrackingResolver.self
        let dependencies: (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>
        if includeNestedDependencies {
            dependencies = dependencyRetriever.dependencies(for:version:)
        } else {
            dependencies = { _, _ in .empty }
        }

        let resolver = resolver ?? resolverClass.init(
            versionsForDependency: dependencyRetriever.versions(for:),
            dependenciesForDependency: dependencies,
            resolvedGitReference: dependencyRetriever.resolvedGitReference
        )

        let outdatedDependencies = SignalProducer
            .combineLatest(
                loadResolvedCartfile(),
                updatedResolvedCartfile(resolver: resolver),
                latestDependencies(resolver: resolver)
            )
            .map { ($0.dependencies, $1.dependencies, $2) }
            .map { currentDependencies, updatedDependencies, latestDependencies -> [OutdatedDependency] in
                return updatedDependencies.compactMap { project, version -> OutdatedDependency? in
                    if let resolved = currentDependencies[project], let latest = latestDependencies[project], resolved != version || resolved != latest {
                        if Version.from(resolved).value == nil, version == resolved {
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

    /// Updates the dependencies of the project to the latest version. The
    /// changes will be reflected in Cartfile.resolved, and also in the working
    /// directory checkouts if the given parameter is true.
    public func updateDependencies(
        shouldCheckout: Bool = true,
        buildOptions: BuildOptions,
        dependenciesToUpdate: [String]? = nil
        ) -> SignalProducer<(), CarthageError> {
        let resolverClass = BackTrackingResolver.self
        let resolver = resolverClass.init(
            versionsForDependency: dependencyRetriever.versions(for:),
            dependenciesForDependency: dependencyRetriever.dependencies(for:version:),
            resolvedGitReference: dependencyRetriever.resolvedGitReference
        )

        return updatedResolvedCartfile(dependenciesToUpdate, resolver: resolver)
            .attemptMap { resolvedCartfile -> Result<(), CarthageError> in
                return self.writeResolvedCartfile(resolvedCartfile)
            }
            .then(shouldCheckout ? checkoutResolvedDependencies(dependenciesToUpdate, buildOptions: buildOptions) : .empty)
    }

    /// Unzips the file at the given URL and copies the frameworks, DSYM and
    /// bcsymbolmap files into the corresponding folders for the project. This
    /// step will also check framework compatibility and create a version file
    /// for the given frameworks.
    ///
    /// Sends the temporary URL of the unzipped directory
    private func unarchiveAndCopyBinaryFrameworks(
        zipFile: URL,
        projectName: String,
        pinnedVersion: PinnedVersion,
        toolchain: String?
        ) -> SignalProducer<URL, CarthageError> {
        return SignalProducer<URL, CarthageError>(value: zipFile)
            .flatMap(.concat, unarchive(archive:))
            .flatMap(.concat) { directoryURL -> SignalProducer<URL, CarthageError> in
                return frameworksInDirectory(directoryURL)
                    .flatMap(.merge) { url -> SignalProducer<URL, CarthageError> in
                        return checkFrameworkCompatibility(url, usingToolchain: toolchain)
                            .mapError { error in CarthageError.internalError(description: error.description) }
                    }
                    .flatMap(.merge, self.copyFrameworkToBuildFolder)
                    .flatMap(.merge) { frameworkURL -> SignalProducer<URL, CarthageError> in
                        return self.copyDSYMToBuildFolderForFramework(frameworkURL, fromDirectoryURL: directoryURL)
                            .then(self.copyBCSymbolMapsToBuildFolderForFramework(frameworkURL, fromDirectoryURL: directoryURL))
                            .then(SignalProducer(value: frameworkURL))
                    }
                    .collect()
                    .flatMap(.concat) { frameworkURLs -> SignalProducer<(), CarthageError> in
                        return self.createVersionFilesForFrameworks(
                            frameworkURLs,
                            fromDirectoryURL: directoryURL,
                            projectName: projectName,
                            commitish: pinnedVersion.commitish
                        )
                    }
                    .then(SignalProducer<URL, CarthageError>(value: directoryURL))
        }
    }

    /// Removes the file located at the given URL
    ///
    /// Sends empty value on successful removal
    private func removeItem(at url: URL) -> SignalProducer<(), CarthageError> {
        return SignalProducer {
            Result(at: url, attempt: FileManager.default.removeItem(at:))
        }
    }

    /// Installs binaries and debug symbols for the given project, if available.
    ///
    /// Sends a boolean indicating whether binaries were installed.
    private func installBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, toolchain: String?) -> SignalProducer<Bool, CarthageError> {
        switch dependency {
        case let .gitHub(server, repository):
            let client = Client(server: server)
            return dependencyRetriever.downloadMatchingBinaries(for: dependency, pinnedVersion: pinnedVersion, fromRepository: repository, client: client)
                .flatMapError { error -> SignalProducer<URL, CarthageError> in
                    if !client.isAuthenticated {
                        return SignalProducer(error: error)
                    }
                    return self.dependencyRetriever.downloadMatchingBinaries(
                        for: dependency,
                        pinnedVersion: pinnedVersion,
                        fromRepository: repository,
                        client: Client(server: server, isAuthenticated: false)
                    )
                }
                .flatMap(.concat) {
                    return self.unarchiveAndCopyBinaryFrameworks(zipFile: $0, projectName: dependency.name, pinnedVersion: pinnedVersion, toolchain: toolchain)
                }
                .flatMap(.concat) { self.removeItem(at: $0) }
                .map { true }
                .flatMapError { error in
                    self.projectEventsObserver.send(value: .skippedInstallingBinaries(dependency: dependency, error: error))
                    return SignalProducer(value: false)
                }
                .concat(value: false)
                .take(first: 1)

        case .git, .binary:
            return SignalProducer(value: false)
        }
    }

    /// Copies the framework at the given URL into the current project's build
    /// folder.
    ///
    /// Sends the URL to the framework after copying.
    private func copyFrameworkToBuildFolder(_ frameworkURL: URL) -> SignalProducer<URL, CarthageError> {
        return platformForFramework(frameworkURL)
            .flatMap(.merge) { platform -> SignalProducer<URL, CarthageError> in
                let platformFolderURL = self.directoryURL.appendingPathComponent(platform.relativePath, isDirectory: true)
                return SignalProducer(value: frameworkURL)
                    .copyFileURLsIntoDirectory(platformFolderURL)
        }
    }

    /// Copies the DSYM matching the given framework and contained within the
    /// given directory URL to the directory that the framework resides within.
    ///
    /// If no dSYM is found for the given framework, completes with no values.
    ///
    /// Sends the URL of the dSYM after copying.
    public func copyDSYMToBuildFolderForFramework(_ frameworkURL: URL, fromDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        let destinationDirectoryURL = frameworkURL.deletingLastPathComponent()
        return dSYMForFramework(frameworkURL, inDirectoryURL: directoryURL)
            .copyFileURLsIntoDirectory(destinationDirectoryURL)
    }

    /// Copies any *.bcsymbolmap files matching the given framework and contained
    /// within the given directory URL to the directory that the framework
    /// resides within.
    ///
    /// If no bcsymbolmap files are found for the given framework, completes with
    /// no values.
    ///
    /// Sends the URLs of the bcsymbolmap files after copying.
    public func copyBCSymbolMapsToBuildFolderForFramework(_ frameworkURL: URL, fromDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        let destinationDirectoryURL = frameworkURL.deletingLastPathComponent()
        return BCSymbolMapsForFramework(frameworkURL, inDirectoryURL: directoryURL)
            .copyFileURLsIntoDirectory(destinationDirectoryURL)
    }

    /// Creates a .version file for all of the provided frameworks.
    public func createVersionFilesForFrameworks(
        _ frameworkURLs: [URL],
        fromDirectoryURL directoryURL: URL,
        projectName: String,
        commitish: String
        ) -> SignalProducer<(), CarthageError> {
        return createVersionFileForCommitish(commitish, dependencyName: projectName, buildProducts: frameworkURLs, rootDirectoryURL: self.directoryURL)
    }

    public func buildOrderForResolvedCartfile(
        _ cartfile: ResolvedCartfile,
        dependenciesToInclude: [String]? = nil
        ) -> SignalProducer<(Dependency, PinnedVersion), CarthageError> {
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
                return self.dependencyRetriever.dependencySet(for: dependency, version: version, mapping: { cartfile.dependency(for: $0.name) ?? $0 })
                    .map { dependencies in
                        [dependency: dependencies]
                }
            }
            .reduce(into: [:]) { (working: inout DependencyGraph, next: DependencyGraph) in
                for (key, value) in next {
                    working.updateValue(value, forKey: key)
                }
            }
            .flatMap(.latest) { (graph: DependencyGraph) -> SignalProducer<(Dependency, PinnedVersion), CarthageError> in
                let dependenciesToInclude = Set(graph
                    .map { dependency, _ in dependency }
                    .filter { dependency in dependenciesToInclude?.contains(dependency.name) ?? false })

                guard let sortedDependencies = topologicalSort(graph, nodes: dependenciesToInclude) else { // swiftlint:disable:this single_line_guard
                    return SignalProducer(error: .dependencyCycle(graph))
                }

                let sortedPinnedDependencies = cartfile.dependencies.keys
                    .filter { dependency in sortedDependencies.contains(dependency) }
                    .sorted { left, right in sortedDependencies.index(of: left)! < sortedDependencies.index(of: right)! }
                    .map { ($0, cartfile.dependencies[$0]!) }

                return SignalProducer(sortedPinnedDependencies)
        }
    }

    /// Checks out the dependencies listed in the project's Cartfile.resolved,
    /// optionally they are limited by the given list of dependency names.
    public func checkoutResolvedDependencies(_ dependenciesToCheckout: [String]? = nil, buildOptions: BuildOptions?) -> SignalProducer<(), CarthageError> {
        /// Determine whether the repository currently holds any submodules (if
        /// it even is a repository).
        let submodulesSignal = submodulesInRepository(self.directoryURL)
            .reduce(into: [:]) { (submodulesByPath: inout [String: Submodule], submodule) in
                submodulesByPath[submodule.path] = submodule
        }

        return loadResolvedCartfile()
            .flatMap(.latest) { resolvedCartfile -> SignalProducer<([String]?, ResolvedCartfile), CarthageError> in
                guard let dependenciesToCheckout = dependenciesToCheckout else {
                    return SignalProducer(value: (nil, resolvedCartfile))
                }

                return self.dependencyRetriever
                    .transitiveDependencies(dependenciesToCheckout, resolvedCartfile: resolvedCartfile)
                    .map { (dependenciesToCheckout + $0, resolvedCartfile) }
            }
            .map { dependenciesToCheckout, resolvedCartfile -> [(Dependency, PinnedVersion)] in
                return resolvedCartfile.dependencies
                    .filter { dep, _ in dependenciesToCheckout?.contains(dep.name) ?? true }
            }
            .zip(with: submodulesSignal)
            .flatMap(.merge) { dependencies, submodulesByPath -> SignalProducer<(), CarthageError> in
                return SignalProducer<(Dependency, PinnedVersion), CarthageError>(dependencies)
                    .flatMap(.concurrent(limit: 4)) { dependency, version -> SignalProducer<(), CarthageError> in
                        switch dependency {
                        case .git, .gitHub:
                            return self.dependencyRetriever.checkoutOrCloneDependency(dependency, version: version, submodulesByPath: submodulesByPath)
                        case .binary:
                            return .empty
                        }
                }
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }

    private func installBinariesForBinaryProject(
        binary: BinaryURL,
        pinnedVersion: PinnedVersion,
        projectName: String,
        toolchain: String?
        ) -> SignalProducer<(), CarthageError> {
        return SignalProducer<Version, ScannableError>(result: Version.from(pinnedVersion))
            .mapError { CarthageError(scannableError: $0) }
            .combineLatest(with: dependencyRetriever.downloadBinaryFrameworkDefinition(binary: binary))
            .attemptMap { semanticVersion, binaryProject -> Result<(Version, URL), CarthageError> in
                guard let frameworkURL = binaryProject.versions[pinnedVersion] else {
                    return .failure(CarthageError.requiredVersionNotFound(Dependency.binary(binary), VersionSpecifier.exactly(semanticVersion)))
                }

                return .success((semanticVersion, frameworkURL))
            }
            .flatMap(.concat) { semanticVersion, frameworkURL in
                return self.dependencyRetriever.downloadBinary(dependency: Dependency.binary(binary), version: semanticVersion, url: frameworkURL)
            }
            .flatMap(.concat) { self.unarchiveAndCopyBinaryFrameworks(zipFile: $0, projectName: projectName, pinnedVersion: pinnedVersion, toolchain: toolchain) }
            .flatMap(.concat) { self.removeItem(at: $0) }
    }

    /// Attempts to build each Carthage dependency that has been checked out,
    /// optionally they are limited by the given list of dependency names.
    /// Cached dependencies whose dependency trees are also cached will not
    /// be rebuilt unless otherwise specified via build options.
    ///
    /// Returns a producer-of-producers representing each scheme being built.
    public func buildCheckedOutDependenciesWithOptions( // swiftlint:disable:this cyclomatic_complexity function_body_length
        _ options: BuildOptions,
        dependenciesToBuild: [String]? = nil,
        sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) }
        ) -> BuildSchemeProducer {
        return loadResolvedCartfile()
            .flatMap(.concat) { resolvedCartfile -> SignalProducer<(Dependency, PinnedVersion), CarthageError> in
                return self.buildOrderForResolvedCartfile(resolvedCartfile, dependenciesToInclude: dependenciesToBuild)
            }
            .flatMap(.concat) { arg -> SignalProducer<((Dependency, PinnedVersion), Set<Dependency>, Bool?), CarthageError> in
                let (dependency, version) = arg
                return SignalProducer.combineLatest(
                    SignalProducer(value: (dependency, version)),
                    self.dependencyRetriever.dependencySet(for: dependency, version: version),
                    versionFileMatches(dependency, version: version, platforms: options.platforms, rootDirectoryURL: self.directoryURL, toolchain: options.toolchain)
                )
            }
            .reduce([]) { includedDependencies, nextGroup -> [(Dependency, PinnedVersion)] in
                let (nextDependency, projects, matches) = nextGroup

                var dependenciesIncludingNext = includedDependencies
                dependenciesIncludingNext.append(nextDependency)

                let projectsToBeBuilt = Set(includedDependencies.map { $0.0 })

                guard options.cacheBuilds && projects.isDisjoint(with: projectsToBeBuilt) else {
                    return dependenciesIncludingNext
                }

                guard let versionFileMatches = matches else {
                    self.projectEventsObserver.send(value: .buildingUncached(nextDependency.0))
                    return dependenciesIncludingNext
                }

                if versionFileMatches {
                    self.projectEventsObserver.send(value: .skippedBuildingCached(nextDependency.0))
                    return includedDependencies
                } else {
                    self.projectEventsObserver.send(value: .rebuildingCached(nextDependency.0))
                    return dependenciesIncludingNext
                }
            }
            .flatMap(.concat) { (dependencies: [(Dependency, PinnedVersion)]) -> SignalProducer<(Dependency, PinnedVersion), CarthageError> in
                return SignalProducer(dependencies)
                    .flatMap(.concurrent(limit: 4)) { dependency, version -> SignalProducer<(Dependency, PinnedVersion), CarthageError> in
                        switch dependency {
                        case .git, .gitHub:
                            guard options.useBinaries else {
                                return .empty
                            }
                            return self.installBinaries(for: dependency, pinnedVersion: version, toolchain: options.toolchain)
                                .filterMap { installed -> (Dependency, PinnedVersion)? in
                                    return installed ? (dependency, version) : nil
                            }
                        case let .binary(binary):
                            return self.installBinariesForBinaryProject(binary: binary, pinnedVersion: version, projectName: dependency.name, toolchain: options.toolchain)
                                .then(.init(value: (dependency, version)))
                        }
                    }
                    .flatMap(.merge) { dependency, version -> SignalProducer<(Dependency, PinnedVersion), CarthageError> in
                        // Symlink the build folder of binary downloads for consistency with regular checkouts
                        // (even though it's not necessary since binary downloads aren't built by Carthage)
                        return self.symlinkBuildPathIfNeeded(for: dependency, version: version)
                            .then(.init(value: (dependency, version)))
                    }
                    .collect()
                    .map { installedDependencies -> [(Dependency, PinnedVersion)] in
                        // Filters out dependencies that we've downloaded binaries for
                        // but preserves the build order
                        return dependencies.filter { dependency -> Bool in
                            !installedDependencies.contains { $0 == dependency }
                        }
                    }
                    .flatten()
            }
            .flatMap(.concat) { dependency, version -> BuildSchemeProducer in
                let dependencyPath = self.directoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true).path
                if !FileManager.default.fileExists(atPath: dependencyPath) {
                    return .empty
                }

                var options = options
                let baseURL = options.derivedDataPath.flatMap(URL.init(string:)) ?? Constants.Dependency.derivedDataURL
                let derivedDataPerXcode = baseURL.appendingPathComponent(self.xcodeVersionDirectory, isDirectory: true)
                let derivedDataPerDependency = derivedDataPerXcode.appendingPathComponent(dependency.name, isDirectory: true)
                let derivedDataVersioned = derivedDataPerDependency.appendingPathComponent(version.commitish, isDirectory: true)
                options.derivedDataPath = derivedDataVersioned.resolvingSymlinksInPath().path

                return self.symlinkBuildPathIfNeeded(for: dependency, version: version)
                    .then(build(dependency: dependency, version: version, self.directoryURL, withOptions: options, sdkFilter: sdkFilter))
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
                                return createVersionFileForCommitish(version.commitish,
                                                                     dependencyName: dependency.name,
                                                                     platforms: options.platforms,
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

    private func symlinkBuildPathIfNeeded(for dependency: Dependency, version: PinnedVersion) -> SignalProducer<(), CarthageError> {
        return dependencyRetriever.dependencySet(for: dependency, version: version)
            .flatMap(.merge) { dependencies -> SignalProducer<(), CarthageError> in
                // Don't symlink the build folder if the dependency doesn't have
                // any Carthage dependencies
                if dependencies.isEmpty {
                    return .empty
                }
                return symlinkBuildPath(for: dependency, rootDirectoryURL: self.directoryURL)
        }
    }

    /// Determines whether the requirements specified in this project's Cartfile.resolved
    /// are compatible with the versions specified in the Cartfile for each of those projects.
    ///
    /// Either emits a value to indicate success or an error.
    public func validate(resolvedCartfile: ResolvedCartfile) -> SignalProducer<(), CarthageError> {
        return SignalProducer(value: resolvedCartfile)
            .flatMap(.concat) { (resolved: ResolvedCartfile) -> SignalProducer<([Dependency: PinnedVersion], CompatibilityInfo.Requirements), CarthageError> in
                let requirements = self.requirementsByDependency(resolvedCartfile: resolved, tryCheckoutDirectory: true)
                return SignalProducer.zip(SignalProducer(value: resolved.dependencies), requirements)
            }
            .flatMap(.concat) { (info: ([Dependency: PinnedVersion], CompatibilityInfo.Requirements)) -> SignalProducer<[CompatibilityInfo], CarthageError> in
                let (dependencies, requirements) = info
                return .init(result: CompatibilityInfo.incompatibilities(for: dependencies, requirements: requirements))
            }
            .flatMap(.concat) { incompatibilities -> SignalProducer<(), CarthageError> in
                return incompatibilities.isEmpty ? .init(value: ()) : .init(error: .invalidResolvedCartfile(incompatibilities))
        }
    }
}

/// Creates symlink between the dependency build folder and the root build folder
///
/// Returns a signal indicating success
private func symlinkBuildPath(for dependency: Dependency, rootDirectoryURL: URL) -> SignalProducer<(), CarthageError> {
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
                                let linkDestinationPath = relativeLinkDestination(for: dependency, subdirectory: Constants.binariesFolderPath)
                                return try fileManager.createSymbolicLink(atPath: $0.path, withDestinationPath: linkDestinationPath)
                            }
                        })
                }
        }
    }
}

/// Sends the URL to each file found in the given directory conforming to the
/// given type identifier. If no type identifier is provided, all files are sent.
private func filesInDirectory(_ directoryURL: URL, _ typeIdentifier: String? = nil) -> SignalProducer<URL, CarthageError> {
    let producer = FileManager.default.reactive
        .enumerator(at: directoryURL, includingPropertiesForKeys: [ .typeIdentifierKey ], options: [ .skipsHiddenFiles, .skipsPackageDescendants ], catchErrors: true)
        .map { _, url in url }
    if let typeIdentifier = typeIdentifier {
        return producer
            .filter { url in
                return url.typeIdentifier
                    .analysis(ifSuccess: { identifier in
                        return UTTypeConformsTo(identifier as CFString, typeIdentifier as CFString)
                    }, ifFailure: { _ in false })
        }
    } else {
        return producer
    }
}

/// Sends the platform specified in the given Info.plist.
func platformForFramework(_ frameworkURL: URL) -> SignalProducer<Platform, CarthageError> {
    return SignalProducer(value: frameworkURL)
        // Neither DTPlatformName nor CFBundleSupportedPlatforms can not be used
        // because Xcode 6 and below do not include either in macOS frameworks.
        .attemptMap { url -> Result<String, CarthageError> in
            let bundle = Bundle(url: url)

            func readFailed(_ message: String) -> CarthageError {
                let error = Result<(), NSError>.error(message)
                return .readFailed(frameworkURL, error)
            }

            func sdkNameFromExecutable() -> String? {
                guard let executableURL = bundle?.executableURL else {
                    return nil
                }

                let task = Task("/usr/bin/xcrun", arguments: ["otool", "-lv", executableURL.path])

                let sdkName: String? = task.launch(standardInput: nil)
                    .ignoreTaskData()
                    .map { String(data: $0, encoding: .utf8) ?? "" }
                    .filter { !$0.isEmpty }
                    .flatMap(.merge) { (output: String) -> SignalProducer<String, NoError> in
                        output.linesProducer
                    }
                    .filter { $0.contains("LC_VERSION") }
                    .take(last: 1)
                    .map { lcVersionLine -> String? in
                        let sdkString = lcVersionLine.split(separator: "_")
                            .last
                            .flatMap(String.init)
                            .flatMap { $0.lowercased() }

                        return sdkString
                    }
                    .skipNil()
                    .single()?
                    .value

                return sdkName
            }

            // Try to read what platfrom this binary is for. Attempt in order:
            // 1. Read `DTSDKName` from Info.plist.
            //  Some users are reporting that static frameworks don't have this key in the .plist,
            //  so we fall back and check the binary of the executable itself.
            // 2. Read the LC_VERSION_<PLATFORM> from the framework's binary executable file

            if let sdkNameFromBundle = bundle?.object(forInfoDictionaryKey: "DTSDKName") as? String {
                return .success(sdkNameFromBundle)
            } else if let sdkNameFromExecutable = sdkNameFromExecutable() {
                return .success(sdkNameFromExecutable)
            } else {
                return .failure(readFailed("could not determine platform neither from DTSDKName key in plist nor from the framework's executable"))
            }
        }
        // Thus, the SDK name must be trimmed to match the platform name, e.g.
        // macosx10.10 -> macosx
        .map { sdkName in sdkName.trimmingCharacters(in: CharacterSet.letters.inverted) }
        .attemptMap { platform in SDK.from(string: platform).map { $0.platform } }
}

/// Sends the URL to each framework bundle found in the given directory.
internal func frameworksInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
    return filesInDirectory(directoryURL, kUTTypeFramework as String)
        .filter { !$0.pathComponents.contains("__MACOSX") }
        .filter { url in
            // Skip nested frameworks
            let frameworksInURL = url.pathComponents.filter { pathComponent in
                return (pathComponent as NSString).pathExtension == "framework"
            }
            return frameworksInURL.count == 1
        }.filter { url in
            // For reasons of speed and the fact that CLI-output structures can change,
            // first try the safer method of reading the ‘Info.plist’ from the Framework’s bundle.
            let bundle = Bundle(url: url)
            let packageType: PackageType? = bundle?.packageType

            switch packageType {
            case .framework?, .bundle?:
                return true
            default:
                // In case no Info.plist exists check the Mach-O fileType
                guard let executableURL = bundle?.executableURL else {
                    return false
                }

                return MachHeader.headers(forMachOFileAtUrl: executableURL)
                    .filter { MachHeader.carthageSupportedFileTypes.contains($0.fileType) }
                    .reduce(into: Set<UInt32>()) { $0.insert($1.fileType); return }
                    .map { $0.count == 1 }
                    .single()?
                    .value ?? false
            }
    }
}

/// Sends the URL to each dSYM found in the given directory
internal func dSYMsInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
    return filesInDirectory(directoryURL, "com.apple.xcode.dsym")
}

/// Sends the URL of the dSYM whose UUIDs match those of the given framework, or
/// errors if there was an error parsing a dSYM contained within the directory.
private func dSYMForFramework(_ frameworkURL: URL, inDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
    return UUIDsForFramework(frameworkURL)
        .flatMap(.concat) { (frameworkUUIDs: Set<UUID>) in
            return dSYMsInDirectory(directoryURL)
                .flatMap(.merge) { dSYMURL in
                    return UUIDsForDSYM(dSYMURL)
                        .filter { (dSYMUUIDs: Set<UUID>) in
                            return dSYMUUIDs == frameworkUUIDs
                        }
                        .map { _ in dSYMURL }
            }
        }
        .take(first: 1)
}

/// Sends the URL to each bcsymbolmap found in the given directory.
internal func BCSymbolMapsInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
    return filesInDirectory(directoryURL)
        .filter { url in url.pathExtension == "bcsymbolmap" }
}

/// Sends the URLs of the bcsymbolmap files that match the given framework and are
/// located somewhere within the given directory.
private func BCSymbolMapsForFramework(_ frameworkURL: URL, inDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
    return UUIDsForFramework(frameworkURL)
        .flatMap(.merge) { uuids -> SignalProducer<URL, CarthageError> in
            if uuids.isEmpty {
                return .empty
            }
            func filterUUIDs(_ signal: Signal<URL, CarthageError>) -> Signal<URL, CarthageError> {
                var remainingUUIDs = uuids
                let count = remainingUUIDs.count
                return signal
                    .filter { fileURL in
                        let basename = fileURL.deletingPathExtension().lastPathComponent
                        if let fileUUID = UUID(uuidString: basename) {
                            return remainingUUIDs.remove(fileUUID) != nil
                        } else {
                            return false
                        }
                    }
                    .take(first: count)
            }
            return BCSymbolMapsInDirectory(directoryURL)
                .lift(filterUUIDs)
    }
}

/// Returns the string representing a relative path from a dependency back to the root
internal func relativeLinkDestination(for dependency: Dependency, subdirectory: String) -> String {
    let dependencySubdirectoryPath = (dependency.relativePath as NSString).appendingPathComponent(subdirectory)
    let componentsForGettingTheHellOutOfThisRelativePath = Array(repeating: "..", count: (dependencySubdirectoryPath as NSString).pathComponents.count - 1)

    // Directs a link from, e.g., /Carthage/Checkouts/ReactiveCocoa/Carthage/Build to /Carthage/Build
    let linkDestinationPath = componentsForGettingTheHellOutOfThisRelativePath.reduce(subdirectory) { trailingPath, pathComponent in
        return (pathComponent as NSString).appendingPathComponent(trailingPath)
    }

    return linkDestinationPath
}

// Diagnostic methods to be able to diagnose problems with the resolver with dependencies
// which cannot be tested 'live', e.g. for private repositories
extension Project {

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
                                  eventObserver: ((DependencyCrawlerEvent) -> Void)? = nil) -> SignalProducer<(Cartfile, ResolvedCartfile?), CarthageError> {
        let crawler = DependencyCrawler(
            versionsForDependency: dependencyRetriever.versions(for:),
            dependenciesForDependency: dependencyRetriever.dependencies(for:version:),
            resolvedGitReference: dependencyRetriever.resolvedGitReference,
            store: store,
            mappings: dependencyMappings,
            ignoreErrors: ignoreErrors
        )

        if let observer = eventObserver {
            crawler.events.observeValues(observer)
        }

        let resolvedCartfile: SignalProducer<ResolvedCartfile?, CarthageError> = loadResolvedCartfile()
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

    /// Updates dependencies by using the specified local dependency store instead of 'live' lookup for dependencies and their versions
    /// Returns a signal with the resulting ResolvedCartfile upon success or a CarthageError upon failure.
    public func resolveUpdatedDependencies(
        from store: LocalDependencyStore,
        resolverType: ResolverProtocol.Type,
        dependenciesToUpdate: [String]? = nil) -> SignalProducer<ResolvedCartfile, CarthageError> {
        let resolver = resolverType.init(
            versionsForDependency: store.versions(for:),
            dependenciesForDependency: store.dependencies(for:version:),
            resolvedGitReference: store.resolvedGitReference
        )

        return updatedResolvedCartfile(dependenciesToUpdate, resolver: resolver)
    }
}
