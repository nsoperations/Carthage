//
//  GitOperations.swift
//  CarthageKit
//
//  Created by Werner Altewischer on 29/03/2019.
//

import Foundation
import Result
import ReactiveSwift
import Tentacle
import XCDBLD
import ReactiveTask

public protocol DependencyRetrieverProtocol {
    func dependencies(
        for dependency: Dependency,
        version: PinnedVersion,
        tryCheckoutDirectory: Bool
        ) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>
    func resolvedGitReference(_ dependency: Dependency, reference: String) -> SignalProducer<PinnedVersion, CarthageError>
    func versions(for dependency: Dependency) -> SignalProducer<PinnedVersion, CarthageError>
}

extension DependencyRetrieverProtocol {
    /// Resolves the specified git ref to a commit hash
    public func resolvedCommitHash(for ref: String, dependency: Dependency) -> Result<String, CarthageError> {
        guard !ref.isGitCommitSha else {
            return .success(ref)
        }
        return resolvedGitReference(dependency, reference: ref).first()?.map { $0.commitish } ?? Result.failure(CarthageError.requiredVersionNotFound(dependency, .gitReference(ref)))
    }

    /// Loads the dependencies for the given dependency, at the given version.
    public func dependencies(for dependency: Dependency, version: PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
        return self.dependencies(for: dependency, version: version, tryCheckoutDirectory: false)
    }
    
    public func prefetch(dependencies: [Dependency: VersionSpecifier], includedDependencyNames: [String]? = nil) -> SignalProducer<(), CarthageError> {
        
        let lock = NSLock()
        let fetchQueue = ObservableAtomic(Set<Dependency>())
        var handledDependencies = Set<Dependency>()
        var dependenciesToFetch: [Dependency: VersionSpecifier] = dependencies.filter({ entry -> Bool in
            includedDependencyNames?.contains(entry.key.name) ?? true
        })
        
        return SignalProducer<(Dependency, VersionSpecifier), CarthageError> { observer, lifetime in
                while !lifetime.hasEnded {
                    let next = lock.locked({ () -> (Dependency, VersionSpecifier)? in
                        if let next = dependenciesToFetch.popFirst() {
                            handledDependencies.insert(next.key)
                            return next
                        }
                        return nil
                    })
                    
                    if let (dependency, versionSpecifier) = next {
                        fetchQueue.modify { $0.insert(dependency) }
                        observer.send(value: (dependency, versionSpecifier))
                    } else {
                        let fetchCount = fetchQueue.value.count
                        if fetchCount == 0 {
                            observer.sendCompleted()
                            break
                        } else {
                            // Wait until a fetch completes
                            fetchQueue.wait { $0.count < fetchCount }
                        }
                    }
                }
            }
            .flatMap(.merge) { (dependency, versionSpecifier) -> SignalProducer<(), CarthageError> in
                return self.mostRelevantDependenciesFor(dependency: dependency, versionSpecifier: versionSpecifier)
                    .flatMap(.concat) { transitiveDependency, transitiveVersionSpecifier -> SignalProducer<(), CarthageError> in
                        lock.locked {
                            if dependenciesToFetch[transitiveDependency] == nil && !handledDependencies.contains(transitiveDependency) {
                                dependenciesToFetch[transitiveDependency] = transitiveVersionSpecifier
                            }
                        }
                        return SignalProducer<(), CarthageError>.empty
                    }
                    .on(terminated: {
                        _ = fetchQueue.modify { $0.remove(dependency) }
                    })
            }
    }
    
    private func mostRelevantDependenciesFor(dependency: Dependency, versionSpecifier: VersionSpecifier) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
        return SignalProducer(value: (dependency, versionSpecifier))
            .flatMap(.concat) { entry -> SignalProducer<PinnedVersion, CarthageError> in
                let (dependency, versionSpecifier) = entry
                switch versionSpecifier {
                case .empty:
                    return SignalProducer.empty
                case let .gitReference(comittish):
                    return self.resolvedGitReference(dependency, reference: comittish)
                default:
                    return self.versions(for: dependency).filter { versionSpecifier.isSatisfied(by: $0) }
                }
            }
            .map(ConcreteVersion.init(pinnedVersion:))
            .collect()
            .map { $0.sorted().first?.pinnedVersion }
            .flatMap(.concat) { mostRelevantVersion -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> in
                if let version = mostRelevantVersion {
                    return self.dependencies(for: dependency, version: version, tryCheckoutDirectory: false)
                } else {
                    return SignalProducer.empty
                }
        }
    }
}

public final class ProjectDependencyRetriever: DependencyRetrieverProtocol {

    private typealias CachedVersions = [Dependency: [PinnedVersion]]
    private typealias CachedGitReferences = [DependencyRef: PinnedVersion]

    /// Caches versions to avoid expensive lookups, and unnecessary
    /// fetching/cloning.
    private var cachedVersions: CachedVersions = [:]
    private var cachedGitReferences: CachedGitReferences = [:]
    private let cachedVersionsQueue = SerialProducerQueue(name: "org.carthage.Constants.Project.cachedVersionsQueue")

    private typealias CachedBinaryProjects = [URL: BinaryProject]

    // Cache the binary project definitions in memory to avoid redownloading during carthage operation
    private var cachedBinaryProjects: CachedBinaryProjects = [:]
    private let cachedBinaryProjectsQueue = SerialProducerQueue(name: "org.carthage.Constants.Project.cachedBinaryProjectsQueue")
    private let gitOperationQueue = SerialProducerQueue(name: "org.carthage.Constants.Project.gitOperationQueue")

    let projectEventsObserver: Signal<ProjectEvent, NoError>.Observer?
    var preferHTTPS = true
    var lockTimeout: Int?
    var useSubmodules = false
    var netrc: Netrc? = nil
    let directoryURL: URL

    /// Limits the number of concurrent clones/fetches
    private let cloneOrFetchQueue = ConcurrentProducerQueue(name: "org.carthage.CarthageKit", limit: 4)

    public init(directoryURL: URL, projectEventsObserver: Signal<ProjectEvent, NoError>.Observer? = nil) {
        self.directoryURL = directoryURL
        self.projectEventsObserver = projectEventsObserver
    }

    /// Clones the given dependency to the global repositories folder, or fetches
    /// inside it if it has already been cloned.
    ///
    /// Returns a signal which will send the URL to the repository's folder on
    /// disk once cloning or fetching has completed.
    public func cloneOrFetchDependency(_ dependency: Dependency, commitish: String? = nil) -> SignalProducer<URL, CarthageError> {
        var lock: Lock?
        return cloneOrFetchDependencyLocked(dependency, commitish: commitish)
            .map { urlLock in
                lock = urlLock
                return urlLock.url }
            .on(terminated: {
                lock?.unlock()
            })
    }

    /// Produces the sub dependencies of the given dependency. Uses the checked out directory if able
    public func dependencySet(for dependency: Dependency, version: PinnedVersion, resolvedCartfile: ResolvedCartfile) -> SignalProducer<Set<Dependency>, CarthageError> {
        return self.dependencies(for: dependency, version: version, tryCheckoutDirectory: true)
            .reduce(into: Set<Dependency>(), { set, entry in
                // This is to ensure that dependencies with the same name resolve to the one in the Cartfile.resolved
                let effectiveDependency: Dependency = resolvedCartfile.dependency(for: entry.0.name) ?? entry.0
                set.insert(effectiveDependency)
            })
    }
    
    func resolvedRecursiveDependencySet(for dependency: Dependency, version: PinnedVersion, resolvedCartfile: ResolvedCartfile) -> SignalProducer<Set<PinnedDependency>, CarthageError> {
        return self.recursiveDependencySet(for: dependency, version: version, resolvedCartfile: resolvedCartfile)
            .map { dependencySet -> Set<PinnedDependency> in
                return dependencySet.reduce(into: Set()) { (set, dep) in
                    if let pinnedVersion = resolvedCartfile.dependencies[dep] {
                        set.insert(PinnedDependency(dependency: dep, pinnedVersion: pinnedVersion))
                    }
                }
            }
    }

    public func recursiveDependencySet(for dependency: Dependency, version: PinnedVersion, resolvedCartfile: ResolvedCartfile) -> SignalProducer<Set<Dependency>, CarthageError> {
        return SignalProducer<Set<Dependency>, CarthageError>.init { () -> Result<Set<Dependency>, CarthageError> in
            do {
                let dependencyVersions = resolvedCartfile.dependencies

                let transitiveDependencies: (Dependency, PinnedVersion) throws -> Set<Dependency> = { dependency, version in
                    return try self.dependencySet(for: dependency, version: version, resolvedCartfile: resolvedCartfile).first()?.get() ?? Set<Dependency>()
                }

                var resultSet = Set<Dependency>()
                var unhandledSet = try transitiveDependencies(dependency, version)

                while true {
                    guard let nextDependency = unhandledSet.popFirst() else {
                        break
                    }
                    resultSet.insert(nextDependency)
                    //Find the recursive dependencies for this value
                    guard let nextVersion = dependencyVersions[nextDependency] else {
                        // This is an internal inconsistency
                        throw CarthageError.internalError(description: "Found transitive dependency \(nextDependency) which is not present in the Cartfile.resolved, which should never occur. Please perform a clean bootstrap.")
                    }
                    let nextSet = try transitiveDependencies(nextDependency, nextVersion)
                    for transitiveDependency in nextSet where !resultSet.contains(transitiveDependency) {
                        unhandledSet.insert(transitiveDependency)
                    }
                }
                return .success(resultSet)
            } catch let error as CarthageError {
                return .failure(error)
            } catch {
                return .failure(.internalError(description: "Got unexpected error: \(error)"))
            }
        }
    }

    /// Loads the dependencies for the given dependency, at the given version. Optionally can attempt to read from the Checkout directory
    public func dependencies(
        for dependency: Dependency,
        version: PinnedVersion,
        tryCheckoutDirectory: Bool
        ) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
        switch dependency {
        case .git, .gitHub:
            let revision = version.commitish
            var lock: Lock?
            let cartfileFetch: SignalProducer<Cartfile, CarthageError> = cloneOrFetchDependencyLocked(dependency, commitish: revision)
                .flatMap(.concat) { (urlLock: URLLock) -> SignalProducer<String, CarthageError> in
                    lock = urlLock
                    return Git.contentsOfFileInRepository(urlLock.url, Constants.Project.cartfilePath, revision: revision)
                }
                .flatMapError { _ in .empty }
                .attemptMap(Cartfile.from(string:))
                .on(terminated: {
                    lock?.unlock()
                })

            let cartfileSource: SignalProducer<Cartfile, CarthageError>
            if tryCheckoutDirectory {
                let dependencyURL = self.directoryURL.appendingPathComponent(dependency.relativePath)
                cartfileSource = SignalProducer<Bool, NoError> { () -> Bool in
                        return dependencyURL.isExistingDirectory
                    }
                    .flatMap(.concat) { directoryExists -> SignalProducer<Cartfile, CarthageError> in
                        if directoryExists {
                            return SignalProducer(result: Cartfile.from(fileURL: dependencyURL.appendingPathComponent(Constants.Project.cartfilePath)))
                                .flatMapError { _ in .empty }
                        } else {
                            return cartfileFetch
                        }
                    }
                    .flatMapError { _ in .empty }
            } else {
                cartfileSource = cartfileFetch
            }
            return cartfileSource
                .flatMap(.concat) { cartfile -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> in
                    return SignalProducer(cartfile.dependencies.map { ($0.0, $0.1) })
            }

        case .binary:
            // Binary-only frameworks do not support dependencies
            return .empty
        }
    }
    
    /// Finds all the transitive dependencies for the dependencies to checkout.
    public func transitiveDependencies(
        resolvedCartfile: ResolvedCartfile,
        includedDependencyNames: [String]? = nil
        ) -> SignalProducer<Set<String>, CarthageError> {
        return SignalProducer(value: resolvedCartfile)
            .map { resolvedCartfile -> [(Dependency, PinnedVersion)] in
                return resolvedCartfile.dependencies.filter { dep, _ in includedDependencyNames?.contains(dep.name) ?? true }
            }
            .flatMap(.merge) { dependencies -> SignalProducer<Set<String>, CarthageError> in
                return SignalProducer<(Dependency, PinnedVersion), CarthageError>(dependencies)
                    .flatMap(.merge) { dependency, version -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> in
                        return self.dependencies(for: dependency, version: version)
                    }
                    .reduce(into: Set<String>(), { set, entry in
                        set.insert(entry.0.name)
                    })
        }
    }

    /// Attempts to resolve a Git reference to a version.
    public func resolvedGitReference(_ dependency: Dependency, reference: String) -> SignalProducer<PinnedVersion, CarthageError> {
        return SignalProducer<CachedGitReferences, CarthageError>(value: self.cachedGitReferences)
            .flatMap(.merge) { gitReferences -> SignalProducer<PinnedVersion, CarthageError> in
                let key = DependencyRef(dependency: dependency, ref: reference)
                if let version = gitReferences[key] {
                    return SignalProducer<PinnedVersion, CarthageError>(value: version)
                } else {
                    var lock: Lock?
                    return self.cloneOrFetchDependencyLocked(dependency, commitish: reference)
                        .flatMap(.concat) { (urlLock: URLLock) -> SignalProducer<PinnedVersion, CarthageError> in
                            lock = urlLock
                            let repositoryURL = urlLock.url
                            return Git.resolveReferenceInRepository(repositoryURL, reference)
                                .map(PinnedVersion.init)
                        }.on(
                            terminated: { lock?.unlock() },
                            value: { self.cachedGitReferences[key] = $0 }
                    )
                }
            }
            .startOnQueue(cachedVersionsQueue)
    }

    /// Sends all versions available for the given project.
    ///
    /// This will automatically clone or fetch the project's repository as
    /// necessary.
    public func versions(for dependency: Dependency) -> SignalProducer<PinnedVersion, CarthageError> {
        let fetchVersions: SignalProducer<PinnedVersion, CarthageError>

        switch dependency {
        case .git, .gitHub:
            var lock: Lock?
            fetchVersions = cloneOrFetchDependencyLocked(dependency)
                .flatMap(.merge) { (urlLock: URLLock) -> SignalProducer<String, CarthageError> in
                    lock = urlLock
                    return Git.listTags(urlLock.url) }
                .filterMap {
                    let pinnedVersion = PinnedVersion($0)
                    return pinnedVersion.isSemantic ? pinnedVersion : nil
                }
                .on(terminated: {
                    lock?.unlock()
                })

        case let .binary(binary):
            fetchVersions = downloadBinaryFrameworkDefinition(binary: binary)
                .flatMap(.concat) { binaryProject -> SignalProducer<PinnedVersion, CarthageError> in
                    return SignalProducer(binaryProject.versions)
            }
        }

        return SignalProducer<CachedVersions, CarthageError>(value: self.cachedVersions)
            .flatMap(.merge) { versionsByDependency -> SignalProducer<PinnedVersion, CarthageError> in
                if let versions = versionsByDependency[dependency] {
                    return SignalProducer(versions)
                } else {
                    return fetchVersions
                        .collect()
                        .on(value: { newVersions in
                            self.cachedVersions[dependency] = newVersions
                        })
                        .flatMap(.concat) { versions in SignalProducer<PinnedVersion, CarthageError>(versions) }
                }
            }
            .startOnQueue(cachedVersionsQueue)
            .collect()
            .flatMap(.concat) { versions -> SignalProducer<PinnedVersion, CarthageError> in
                if versions.isEmpty {
                    return SignalProducer(error: .taggedVersionNotFound(dependency))
                }

                return SignalProducer(versions)
        }
    }

    public func downloadBinaryFrameworkDefinition(binary: BinaryURL) -> SignalProducer<BinaryProject, CarthageError> {
        return SignalProducer<CachedBinaryProjects, CarthageError>(value: self.cachedBinaryProjects)
            .flatMap(.merge) { binaryProjectsByURL -> SignalProducer<BinaryProject, CarthageError> in
                if let binaryProject = binaryProjectsByURL[binary.url] {
                    return SignalProducer(value: binaryProject)
                } else {
                    self.projectEventsObserver?.send(value: .downloadingBinaryFrameworkDefinition(.binary(binary), binary.url))
                    return URLSession.shared.reactive.data(with: URLRequest(url: binary.url, netrc: self.netrc))
                        .mapError {
                            CarthageError.readFailed(binary.url, $0 as NSError)
                        }
                        .attemptMap { data, response in
                            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                                return .failure(CarthageError.httpError(statusCode: httpResponse.statusCode))
                            }
                            return BinaryProject.from(jsonData: data).mapError { error in
                                return CarthageError.invalidBinaryJSON(binary.url, error)
                            }
                        }
                        .on(value: { binaryProject in
                            self.cachedBinaryProjects[binary.url] = binaryProject
                        })
                }
            }
            .startOnQueue(self.cachedBinaryProjectsQueue)
    }

    /// Checks out the given dependency into its intended working directory,
    /// cloning it first if need be.
    public func checkoutOrCloneDependency(
        _ dependency: Dependency,
        version: PinnedVersion,
        submodulesByPath: [String: Submodule],
        resolvedCartfile: ResolvedCartfile) -> SignalProducer<(), CarthageError> {
        let revision = version.commitish
        var lock: Lock?
        return cloneOrFetchDependencyLocked(dependency, commitish: revision)
            .flatMap(.merge) { (urlLock: URLLock) -> SignalProducer<(), CarthageError> in
                lock = urlLock
                let repositoryURL = urlLock.url
                let workingDirectoryURL = self.directoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)

                /// The submodule for an already existing submodule at dependency project’s path
                /// or the submodule to be added at this path given the `--use-submodules` flag.
                let submodule: Submodule?

                if var foundSubmodule = submodulesByPath[dependency.relativePath] {
                    foundSubmodule.url = dependency.gitURL(preferHTTPS: self.preferHTTPS)!
                    foundSubmodule.sha = revision
                    submodule = foundSubmodule
                } else if self.useSubmodules {
                    submodule = Submodule(name: dependency.relativePath, path: dependency.relativePath, url: dependency.gitURL(preferHTTPS: self.preferHTTPS)!, sha: revision)
                } else {
                    submodule = nil
                }

                if let submodule = submodule {
                    // In the presence of `submodule` for `dependency` — before symlinking, (not after) — add submodule and its submodules:
                    // `dependency`, subdependencies that are submodules, and non-Carthage-housed submodules.
                    return Git.addSubmoduleToRepository(self.directoryURL, submodule, GitURL(repositoryURL.path))
                        .startOnQueue(self.gitOperationQueue)
                } else {
                    return Git.checkoutRepositoryToDirectory(repositoryURL, workingDirectoryURL, revision: revision)
                        .then(
                            Git.submodulesInRepository(repositoryURL, revision: revision)
                                .flatMap(.merge) {
                                    Git.cloneSubmoduleInWorkingDirectory($0, workingDirectoryURL)
                            }
                    )
                }
            }
            .on(started: {
                self.projectEventsObserver?.send(value: .checkingOut(dependency, revision))
            }, terminated: {
                lock?.unlock()
            })
    }

    /// Clones the given project to the given destination URL (defaults to the global
    /// repositories folder), or fetches inside it if it has already been cloned.
    /// Optionally takes a commitish to check for prior to fetching.
    ///
    /// Returns a signal which will send the operation type once started, and
    /// the URL to where the repository's folder will exist on disk, then complete
    /// when the operation completes.
    public static func cloneOrFetch(
        dependency: Dependency,
        preferHTTPS: Bool,
        lockTimeout: Int? = nil,
        destinationURL: URL = Constants.Dependency.repositoriesURL,
        commitish: String? = nil
        ) -> SignalProducer<(ProjectEvent?, URL), CarthageError> {
        var lock: Lock?
        return cloneOrFetchLocked(dependency: dependency, preferHTTPS: preferHTTPS, lockTimeout: lockTimeout, destinationURL: destinationURL, commitish: commitish)
            .map { projectEvent, urlLock in
                lock = urlLock
                return (projectEvent, urlLock.url) }
            .on(terminated: {
                lock?.unlock()
            })
    }

    /// Installs binaries and debug symbols for the given project, if available.
    ///
    /// Sends a boolean indicating whether binaries were installed.
    public func installBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, resolvedDependencySet: Set<PinnedDependency>, strictMatch: Bool, platforms: Set<Platform>, toolchain: String?, customCacheCommand: String?) -> SignalProducer<Bool, CarthageError> {
        if let cache = self.binariesCache(for: dependency, customCacheCommand: customCacheCommand) {
            return SwiftToolchain.swiftVersion(usingToolchain: toolchain)
                .mapError { error in CarthageError.internalError(description: error.description) }
                .flatMap(.concat) { localSwiftVersion -> SignalProducer<Bool, CarthageError> in
                    var lock: URLLock?
                    let resolvedDependenciesHash = Frameworks.hashForResolvedDependencySet(resolvedDependencySet)
                    return cache.matchingBinary(
                        for: dependency,
                        pinnedVersion: pinnedVersion,
                        configuration: configuration,
                        resolvedDependenciesHash: resolvedDependenciesHash,
                        strictMatch: strictMatch,
                        platforms: platforms,
                        swiftVersion: localSwiftVersion,
                        eventObserver: self.projectEventsObserver,
                        lockTimeout: self.lockTimeout,
                        netrc: self.netrc
                        )
                        .flatMap(.concat) { urlLock -> SignalProducer<Bool, CarthageError> in
                            lock = urlLock
                            if let url = urlLock?.url {
                                self.projectEventsObserver?.send(value: .installingBinaries(dependency, pinnedVersion.description))
                                return self.unarchiveAndCopyBinaryFrameworks(zipFile: url, dependency: dependency, pinnedVersion: pinnedVersion, configuration: configuration, resolvedDependencySet: resolvedDependencySet, swiftVersion: localSwiftVersion)
                                    .then(SignalProducer<Bool, CarthageError>(value: true))
                            } else {
                                return SignalProducer<Bool, CarthageError>(value: false)
                            }
                        }
                        .flatMapError { error -> SignalProducer<Bool, CarthageError> in
                            if let url = lock?.url {
                                _ = try? FileManager.default.removeItem(at: url)
                            }
                            return SignalProducer<Bool, CarthageError>(value: false)
                        }
                        .on(value: { didInstall in
                            if !didInstall {
                                self.projectEventsObserver?.send(value: .skippedInstallingBinaries(dependency: dependency, error: nil))
                            }
                        })
                        .on(terminated: { lock?.unlock() })
                }
                .startOnQueue(globalConcurrentProducerQueue)
        } else {
            return SignalProducer(value: false)
        }
    }

    public func storeBinaries(for dependency: Dependency, frameworkNames: [String], pinnedVersion: PinnedVersion, configuration: String, resolvedDependencySet: Set<PinnedDependency>?, toolchain: String?) -> SignalProducer<URL, CarthageError> {
        if frameworkNames.isEmpty {
            return SignalProducer<URL, CarthageError>.empty
        }
        
        var tempDir: URL?
        return FileManager.default.reactive.createTemporaryDirectory()
            .flatMap(.merge) { tempDirectoryURL -> SignalProducer<URL, CarthageError> in
                tempDir = tempDirectoryURL
                return Archive.archiveFrameworks(frameworkNames: frameworkNames, dependencyName: dependency.name, directoryURL: self.directoryURL, customOutputPath: tempDirectoryURL.appendingPathComponent(dependency.name + ".framework.zip").path)
            }
            .flatMap(.merge) { archiveURL -> SignalProducer<URL, CarthageError> in
                let hash = resolvedDependencySet.map { Frameworks.hashForResolvedDependencySet($0) }
                return SwiftToolchain.swiftVersion(usingToolchain: toolchain)
                    .mapError { error in CarthageError.internalError(description: error.description) }
                    .flatMap(.merge) { swiftVersion -> SignalProducer<URL, CarthageError> in
                        self.projectEventsObserver?.send(value: .storingBinaries(dependency, pinnedVersion.description))
                        return AbstractBinariesCache.storeFile(at: archiveURL, for: dependency, version: pinnedVersion, configuration: configuration, resolvedDependenciesHash: hash, swiftVersion: swiftVersion, lockTimeout: self.lockTimeout, deleteSource: true)
                }
            }
            .on(terminated: {
                tempDir?.removeIgnoringErrors()
            })
    }

    public func installBinariesForBinaryProject(
        binary: BinaryURL,
        pinnedVersion: PinnedVersion,
        configuration: String,
        resolvedDependencySet: Set<PinnedDependency>,
        strictMatch: Bool,
        platforms: Set<Platform>,
        toolchain: String?
        ) -> SignalProducer<(), CarthageError> {

        let dependency = Dependency.binary(binary)

        return SwiftToolchain.swiftVersion(usingToolchain: toolchain)
            .mapError { error in CarthageError.internalError(description: error.description) }
            .flatMap(.concat, { localSwiftVersion -> SignalProducer<(), CarthageError> in
                var lock: URLLock?
                return self.downloadBinaryFrameworkDefinition(binary: binary)
                    .flatMap(.concat) { binaryProject in
                        return self.downloadBinary(dependency: dependency, pinnedVersion: pinnedVersion, binaryProject: binaryProject, configuration: configuration, resolvedDependencySet: resolvedDependencySet, strictMatch: strictMatch, platforms: platforms, swiftVersion: localSwiftVersion)
                    }
                    .flatMap(.concat) { urlLock -> SignalProducer<(), CarthageError> in
                        lock = urlLock
                        self.projectEventsObserver?.send(value: .installingBinaries(dependency, pinnedVersion.description))
                        return self.unarchiveAndCopyBinaryFrameworks(zipFile: urlLock.url, dependency: dependency, pinnedVersion: pinnedVersion, configuration: configuration, resolvedDependencySet: Set(), swiftVersion: localSwiftVersion)
                    }
                    .on(failed: { error in
                        if case .incompatibleFrameworkSwiftVersion = error, let url = lock?.url {
                            _ = try? FileManager.default.removeItem(at: url)
                        }
                    })
                    .on(terminated: { lock?.unlock() })
            })
            .startOnQueue(globalConcurrentProducerQueue)
    }

    // MARK: - Private methods

    private func cloneOrFetchDependencyLocked(_ dependency: Dependency, commitish: String? = nil) -> SignalProducer<URLLock, CarthageError> {
        return ProjectDependencyRetriever.cloneOrFetchLocked(dependency: dependency, preferHTTPS: self.preferHTTPS, lockTimeout: self.lockTimeout, commitish: commitish)
            .on(value: { event, _ in
                if let event = event {
                    self.projectEventsObserver?.send(value: event)
                }
            })
            .map { _, urlLock in urlLock }
            .take(last: 1)
            .startOnQueue(cloneOrFetchQueue)
    }

    private static func cloneOrFetchLocked(
        dependency: Dependency,
        preferHTTPS: Bool,
        lockTimeout: Int?,
        destinationURL: URL = Constants.Dependency.repositoriesURL,
        commitish: String? = nil
        ) -> SignalProducer<(ProjectEvent?, URLLock), CarthageError> {
        let fileManager = FileManager.default
        let repositoryURL = Dependencies.repositoryFileURL(for: dependency, baseURL: destinationURL)
        var lock: URLLock?

        return URLLock.lockReactive(url: repositoryURL, timeout: lockTimeout, onWait: { _ in })
            .map { urlLock in
                lock = urlLock
                return dependency.gitURL(preferHTTPS: preferHTTPS)!
            }
            .flatMap(.merge) { (remoteURL: GitURL) -> SignalProducer<(ProjectEvent?, URLLock), CarthageError> in

                guard let urlLock = lock else {
                    fatalError("Lock should be not nil at this point")
                }

                return Git.isGitRepository(repositoryURL)
                    .flatMap(.merge) { isRepository -> SignalProducer<(ProjectEvent?, URLLock), CarthageError> in

                        // Either the directory didn't exist or it did but wasn't a git repository
                        // (Could happen if the process is killed during a previous directory creation)
                        // So we remove it, then clone
                        let cloneProducer = SignalProducer { () -> Result<(), CarthageError> in
                                _ = try? fileManager.removeItem(at: repositoryURL)
                                return .success(())
                            }
                            .flatMap(.concat) {
                                return SignalProducer(value: (.cloning(dependency), urlLock))
                                    .concat(Git.cloneRepository(remoteURL, repositoryURL)
                                        .then(SignalProducer<(ProjectEvent?, URLLock), CarthageError>.empty)
                                )
                            }
                        
                        let fetchProducer: () -> SignalProducer<(ProjectEvent?, URLLock), CarthageError> = {

                            guard Git.FetchCache.needsFetch(forURL: remoteURL) else {
                                return SignalProducer(value: (nil, urlLock))
                            }

                            return SignalProducer(value: (.fetching(dependency), urlLock))
                                .concat(
                                    Git.fetchRepository(repositoryURL, remoteURL: remoteURL, refspec: "+refs/heads/*:refs/heads/*")
                                        .then(SignalProducer<(ProjectEvent?, URLLock), CarthageError>.empty)
                            )
                        }
                        
                        let fetchOrCloneProducer: () -> SignalProducer<(ProjectEvent?, URLLock), CarthageError> = {
                            return fetchProducer()
                                .flatMapError { error -> SignalProducer<(ProjectEvent?, URLLock), CarthageError> in
                                    let errorDescription = error.description.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let event: (ProjectEvent?, URLLock) = (.warning("Fetch of \(dependency.name) failed, performing a clean clone instead. Error was:\n\(errorDescription)"), urlLock)
                                    return SignalProducer(value: event).concat(cloneProducer)
                            }
                        }
                        
                        if isRepository {
                            if let commitish = commitish {
                                return SignalProducer.zip(
                                    Git.branchExistsInRepository(repositoryURL, pattern: commitish),
                                    Git.commitExistsInRepository(repositoryURL, revision: commitish)
                                    )
                                    .flatMap(.concat) { branchExists, commitExists -> SignalProducer<(ProjectEvent?, URLLock), CarthageError> in
                                        // If the given commitish is a branch, we should fetch.
                                        if branchExists || !commitExists {
                                            return fetchOrCloneProducer()
                                        } else {
                                            return SignalProducer(value: (nil, urlLock))
                                        }
                                }
                            } else {
                                return fetchOrCloneProducer()
                            }
                        } else {
                            return cloneProducer
                        }
                }
            }
    }

    /// Effective binaries cache
    private func binariesCache(for dependency: Dependency, customCacheCommand: String?) -> BinariesCache? {
        if let cacheCommand = customCacheCommand {
            return ExternalTaskBinariesCache(taskCommand: cacheCommand)
        } else {
            switch dependency {
            case let .gitHub(server, repository):
                return GitHubBinariesCache(repository: repository, client: Client(server: server))
            default:
                return LocalBinariesCache()
            }
        }
    }

    /// Caches the downloaded binary at the given URL, moving it to the other URL
    /// given.
    ///
    /// Sends the final file URL upon .success.
    private func cacheDownloadedBinary(_ downloadURL: URL, toURL cachedURL: URL) -> SignalProducer<URL, CarthageError> {
        return SignalProducer(value: cachedURL)
            .attempt { fileURL in
                Result(at: fileURL.deletingLastPathComponent(), attempt: {
                    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                })
            }
            .attempt { newDownloadURL in
                // Tries `rename()` system call at first.
                let result = downloadURL.withUnsafeFileSystemRepresentation { old in
                    newDownloadURL.withUnsafeFileSystemRepresentation { new in
                        rename(old!, new!)
                    }
                }
                if result == 0 {
                    return .success(())
                }

                if errno != EXDEV {
                    return .failure(.taskError(.posixError(errno)))
                }

                // If the “Cross-device link” error occurred, then falls back to
                // `FileManager.moveItem(at:to:)`.
                //
                // See https://github.com/Carthage/Carthage/issues/706 and
                // https://github.com/Carthage/Carthage/issues/711.
                return Result(at: newDownloadURL, attempt: {
                    try FileManager.default.moveItem(at: downloadURL, to: $0)
                })
        }
    }

    /// Downloads the binary only framework file. Sends the URL to each downloaded zip, after it has been moved to a
    /// less temporary location.
    private func downloadBinary(dependency: Dependency, pinnedVersion: PinnedVersion, binaryProject: BinaryProject, configuration: String, resolvedDependencySet: Set<PinnedDependency>, strictMatch: Bool, platforms: Set<Platform>, swiftVersion: PinnedVersion) -> SignalProducer<URLLock, CarthageError> {
        let binariesCache: BinariesCache = BinaryProjectCache(binaryProjectDefinitions: [dependency: binaryProject])
        let resolvedDependenciesHash = Frameworks.hashForResolvedDependencySet(resolvedDependencySet)
        return binariesCache.matchingBinary(for: dependency, pinnedVersion: pinnedVersion, configuration: configuration, resolvedDependenciesHash: resolvedDependenciesHash, strictMatch: strictMatch, platforms: platforms, swiftVersion: swiftVersion, eventObserver: self.projectEventsObserver, lockTimeout: self.lockTimeout, netrc: self.netrc)
            .attemptMap({ urlLock -> Result<URLLock, CarthageError> in
                if let lock = urlLock {
                    return .success(lock)
                } else {
                    //This should not happen, the binaries cache should trigger a read failed error instead
                    return .failure(CarthageError.internalError(description: "Could not download binary file for dependency \(dependency.name) version \(pinnedVersion)"))
                }
            })
    }

    /// Unzips the file at the given URL and copies the frameworks, DSYM and
    /// bcsymbolmap files into the corresponding folders for the project. This
    /// step will also check framework compatibility and create a version file
    /// for the given frameworks.
    private func unarchiveAndCopyBinaryFrameworks(
        zipFile: URL,
        dependency: Dependency,
        pinnedVersion: PinnedVersion,
        configuration: String,
        resolvedDependencySet: Set<PinnedDependency>?,
        swiftVersion: PinnedVersion
        ) -> SignalProducer<(), CarthageError> {

        return SignalProducer<URL, CarthageError>(value: zipFile)
            .flatMap(.concat, Archive.unarchive(archive:))
            .flatMap(.concat) { tempDirectoryURL -> SignalProducer<(), CarthageError> in
                return self.moveBinaries(sourceDirectoryURL: tempDirectoryURL,
                                                  dependency: dependency,
                                                  pinnedVersion: pinnedVersion,
                                                  configuration: configuration,
                                                  resolvedDependencySet: resolvedDependencySet,
                                                  swiftVersion: swiftVersion)
                .on(terminated: { tempDirectoryURL.removeIgnoringErrors() })
        }
    }

    private func moveBinaries(
        sourceDirectoryURL: URL,
        dependency: Dependency,
        pinnedVersion: PinnedVersion,
        configuration: String,
        resolvedDependencySet: Set<PinnedDependency>?,
        swiftVersion: PinnedVersion
        ) -> SignalProducer<(), CarthageError> {
        // Helper type
        typealias SourceURLAndDestinationURL = (frameworkSourceURL: URL, frameworkDestinationURL: URL)

        // Returns the unique pairs in the input array
        // or the duplicate keys by .frameworkDestinationURL
        func uniqueSourceDestinationPairs(
            _ sourceURLAndDestinationURLpairs: [SourceURLAndDestinationURL]
            ) -> Result<[SourceURLAndDestinationURL], CarthageError> {
            let destinationMap = sourceURLAndDestinationURLpairs
                .reduce(into: [URL: [URL]]()) { result, pair in
                    result[pair.frameworkDestinationURL] =
                        (result[pair.frameworkDestinationURL] ?? []) + [pair.frameworkSourceURL]
            }

            let dupes = destinationMap.filter { $0.value.count > 1 }
            guard dupes.count == 0 else {
                return .failure(CarthageError
                    .duplicatesInArchive(duplicates: CarthageError
                        .DuplicatesInArchive(dictionary: dupes)))
            }

            let uniquePairs = destinationMap
                .filter { $0.value.count == 1 }
                .map { SourceURLAndDestinationURL(frameworkSourceURL: $0.value.first!,
                                                  frameworkDestinationURL: $0.key)}
            return .success(uniquePairs)
        }

        let dependencySourceURL = self.directoryURL.appendingPathComponent(dependency.relativePath)

        // For all frameworks in the directory where the archive has been expanded
        return Frameworks.frameworksInDirectory(sourceDirectoryURL)
            .collect()
            // Check if multiple frameworks resolve to the same unique destination URL in the Carthage/Build/ folder.
            // This is needed because frameworks might overwrite each others.
            .flatMap(.merge) { frameworksUrls -> SignalProducer<SourceURLAndDestinationURL, CarthageError> in
                return SignalProducer<URL, CarthageError>(frameworksUrls)
                    .flatMap(.merge) { url -> SignalProducer<URL, CarthageError> in
                        return Frameworks.platformForFramework(url)
                            .attemptMap { self.frameworkURLInCarthageBuildFolder(platform: $0,
                                                                                 sourceURL: url) }
                    }
                    .collect()
                    .flatMap(.merge) { destinationUrls -> SignalProducer<SourceURLAndDestinationURL, CarthageError> in
                        let frameworkUrlAndDestinationUrlPairs = zip(frameworksUrls.map { $0.standardizedFileURL },
                                                                     destinationUrls.map { $0.standardizedFileURL })
                            .map { SourceURLAndDestinationURL(frameworkSourceURL: $0,
                                                              frameworkDestinationURL: $1) }

                        return uniqueSourceDestinationPairs(frameworkUrlAndDestinationUrlPairs)
                            .producer
                            .flatMap(.merge) { SignalProducer($0) }
                }
            }
            // Check if the framework are compatible with the current Swift version
            .flatMap(.merge) { pair -> SignalProducer<SourceURLAndDestinationURL, CarthageError> in
                return Frameworks.checkFrameworkCompatibility(pair.frameworkSourceURL, swiftVersion: swiftVersion)
                    .mapError { error in CarthageError.incompatibleFrameworkSwiftVersion(error.description) }
                    .then(SignalProducer<SourceURLAndDestinationURL, CarthageError>(value: pair))
            }
            // If the framework is compatible copy it over to the destination folder in Carthage/Build
            .flatMap(.merge) { frameworkSourceURL, frameworkDestinationURL -> SignalProducer<URL, CarthageError> in
                let sourceDirectoryURL = frameworkSourceURL.resolvingSymlinksInPath().deletingLastPathComponent()
                let destinationDirectoryURL = frameworkDestinationURL.resolvingSymlinksInPath().deletingLastPathComponent()
                return Frameworks.BCSymbolMapsForFramework(frameworkSourceURL, inDirectoryURL: sourceDirectoryURL)
                    .moveFileURLsIntoDirectory(destinationDirectoryURL)
                    .then(
                        Frameworks.dSYMForFramework(frameworkSourceURL, inDirectoryURL: sourceDirectoryURL)
                            .attemptMap { dsymURL -> Result<URL, CarthageError> in
                                if dependencySourceURL.isExistingDirectory {
                                    return DebugSymbolsMapper.mapSymbolLocations(frameworkURL: frameworkSourceURL, dsymURL: dsymURL, sourceURL: dependencySourceURL, urlPrefixMapping: (sourceDirectoryURL, destinationDirectoryURL))
                                        .map { _ in dsymURL }
                                } else {
                                    return .success(dsymURL)
                                }
                            }
                            .moveFileURLsIntoDirectory(destinationDirectoryURL)
                    )
                    .then(
                        SignalProducer<URL, CarthageError>(value: frameworkSourceURL)
                            .moveFileURLsIntoDirectory(destinationDirectoryURL)
                    )
                    .then(
                        SignalProducer(value: frameworkDestinationURL)
                )
            }
            .collect()
            // Collect .bundle folders as well, for pure binaries or non-framework dependencies
            .flatMap(.merge) { frameworkURLs -> SignalProducer<([URL], [URL]), CarthageError> in
                return Frameworks.bundlesInDirectory(sourceDirectoryURL)
                    .filter { url in
                        let parent = frameworkURLs.first(where: { frameworkURL -> Bool in
                            frameworkURL.isAncestor(of: url)
                        })
                        return parent == nil
                    }
                    .attemptMap { sourceURL -> Result<SourceURLAndDestinationURL, CarthageError> in
                        let platform: Platform? = Frameworks.platformForBundle(sourceURL, relativeTo: sourceDirectoryURL)
                        return self.bundleURLInCarthageBuildFolder(platform: platform, sourceURL: sourceURL)
                            .map { SourceURLAndDestinationURL(frameworkSourceURL: sourceURL.standardizedFileURL, frameworkDestinationURL: $0.standardizedFileURL) }
                    }
                    .collect()
                    .flatMap(.merge) { frameworkUrlAndDestinationUrlPairs -> SignalProducer<SourceURLAndDestinationURL, CarthageError> in
                        return uniqueSourceDestinationPairs(frameworkUrlAndDestinationUrlPairs)
                            .producer
                            .flatMap(.merge) { SignalProducer($0) }
                    }
                    .flatMap(.merge) { sourceURL, destinationURL -> SignalProducer<URL, CarthageError> in
                        let destinationDirectoryURL = destinationURL.resolvingSymlinksInPath().deletingLastPathComponent()
                        return SignalProducer<URL, CarthageError>(value: sourceURL)
                            .moveFileURLsIntoDirectory(destinationDirectoryURL)
                            .then(SignalProducer(value: destinationURL))
                    }
                    .collect()
                    .flatMap(.merge) { bundleURLs -> SignalProducer<([URL], [URL]), CarthageError> in
                        return SignalProducer.init(value: (bundleURLs, frameworkURLs))
                    }
            }
            // Write the .version file
            .flatMap(.concat) { bundleURLs, frameworkURLs -> SignalProducer<(), CarthageError> in
                guard !bundleURLs.isEmpty || !frameworkURLs.isEmpty else {
                    return SignalProducer<(), CarthageError>(error: CarthageError.noInstallableBinariesFoundInArchive(dependency: dependency))
                }

                let versionFileURL = VersionFile.versionFileURL(dependencyName: dependency.name, rootDirectoryURL: sourceDirectoryURL)
                if versionFileURL.isExistingFile {
                    let targetVersionFileURL = VersionFile.versionFileURL(dependencyName: dependency.name, rootDirectoryURL: self.directoryURL)
                    return Files.moveFile(from: versionFileURL, to: targetVersionFileURL)
                        .map { _ in return () }
                } else {
                    return self.createVersionFilesForFrameworks(
                        frameworkURLs,
                        projectName: dependency.name,
                        commitish: pinnedVersion.commitish,
                        configuration: configuration,
                        resolvedDependencySet: resolvedDependencySet
                    )
                }
            }
    }

    /// Constructs the file:// URL at which a given .framework
    /// will be found. Depends on the location of the current project.
    private func frameworkURLInCarthageBuildFolder(
        platform: Platform,
        sourceURL: URL
        ) -> Result<URL, CarthageError> {
        let frameworkNameAndExtension = sourceURL.lastPathComponent
        guard sourceURL.pathExtension == "framework" else {
            return .failure(.internalError(description: "\(frameworkNameAndExtension) is not a valid framework identifier"))
        }

        guard let destinationURLInWorkingDir = platform
            .relativeURL?
            .appendingPathComponent(frameworkNameAndExtension, isDirectory: true) else {
                return .failure(.internalError(description: "failed to construct framework destination url from \(platform) and \(frameworkNameAndExtension)"))
        }

        return .success(self
            .directoryURL
            .appendingPathComponent(destinationURLInWorkingDir.path, isDirectory: true)
            .standardizedFileURL)
    }

    private func bundleURLInCarthageBuildFolder(platform: Platform?, sourceURL: URL) -> Result<URL, CarthageError> {
        let bundleName = sourceURL.lastPathComponent
        guard sourceURL.pathExtension == "bundle" else {
                return .failure(.internalError(description: "\(bundleName) is not a valid bundle identifier"))
        }

        let destinationInWorkingDir = platform?.relativePath.appendingPathComponent(bundleName) ?? Constants.binariesFolderPath.appendingPathComponent(bundleName)
        return .success(self
            .directoryURL
            .appendingPathComponent(destinationInWorkingDir, isDirectory: true)
            .standardizedFileURL)
    }

    /// Creates a .version file for all of the provided frameworks.
    private func createVersionFilesForFrameworks(
        _ frameworkURLs: [URL],
        projectName: String,
        commitish: String,
        configuration: String,
        resolvedDependencySet: Set<PinnedDependency>?
        ) -> SignalProducer<(), CarthageError> {
        return VersionFile.createVersionFileForCommitish(commitish,
                                                         dependencyName: projectName,
                                                         configuration: configuration,
                                                         resolvedDependencySet: resolvedDependencySet,
                                                         buildProducts: frameworkURLs,
                                                         rootDirectoryURL: self.directoryURL)
    }
}

private struct DependencyRef: Hashable {
    public let dependency: Dependency
    public let ref: String
}
