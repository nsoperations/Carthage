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
    let directoryURL: URL

    /// Limits the number of concurrent clones/fetches to the number of active
    /// processors.
    private let cloneOrFetchQueue = ConcurrentProducerQueue(name: "org.carthage.CarthageKit", limit: ProcessInfo.processInfo.activeProcessorCount)

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
    public func dependencySet(for dependency: Dependency, version: PinnedVersion, mapping: ((Dependency) -> Dependency)? = nil) -> SignalProducer<Set<Dependency>, CarthageError> {
        return self.dependencies(for: dependency, version: version, tryCheckoutDirectory: true)
            .map { mapping?($0.0) ?? ($0.0) }
            .collect()
            .map { Set($0) }
            .concat(value: Set())
            .take(first: 1)
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
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: dependencyURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    }
                    .flatMap(.concat) { directoryExists -> SignalProducer<Cartfile, CarthageError> in
                        if directoryExists {
                            return SignalProducer(result: Cartfile.from(file: dependencyURL.appendingPathComponent(Constants.Project.cartfilePath)))
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
        _ dependenciesToCheckout: [String]?,
        resolvedCartfile: ResolvedCartfile
        ) -> SignalProducer<[String], CarthageError> {
        return SignalProducer(value: resolvedCartfile)
            .map { resolvedCartfile -> [(Dependency, PinnedVersion)] in
                return resolvedCartfile.dependencies
                    .filter { dep, _ in dependenciesToCheckout?.contains(dep.name) ?? false }
            }
            .flatMap(.merge) { dependencies -> SignalProducer<[String], CarthageError> in
                return SignalProducer<(Dependency, PinnedVersion), CarthageError>(dependencies)
                    .flatMap(.merge) { dependency, version -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> in
                        return self.dependencies(for: dependency, version: version)
                    }
                    .map { $0.0.name }
                    .collect()
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

                    return URLSession.shared.reactive.data(with: URLRequest(url: binary.url))
                        .mapError { CarthageError.readFailed(binary.url, $0 as NSError) }
                        .attemptMap { data, _ in
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
        submodulesByPath: [String: Submodule]
        ) -> SignalProducer<(), CarthageError> {
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

                let symlinkCheckoutPaths = self.symlinkCheckoutPaths(for: dependency, version: version, withRepository: repositoryURL, atRootDirectory: self.directoryURL)

                if let submodule = submodule {
                    // In the presence of `submodule` for `dependency` — before symlinking, (not after) — add submodule and its submodules:
                    // `dependency`, subdependencies that are submodules, and non-Carthage-housed submodules.
                    return Git.addSubmoduleToRepository(self.directoryURL, submodule, GitURL(repositoryURL.path))
                        .startOnQueue(self.gitOperationQueue)
                        .then(symlinkCheckoutPaths)
                } else {
                    return Git.checkoutRepositoryToDirectory(repositoryURL, workingDirectoryURL, revision: revision)
                        // For checkouts of “ideally bare” repositories of `dependency`, we add its submodules by cloning ourselves, after symlinking.
                        .then(symlinkCheckoutPaths)
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
    public func installBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, platforms: Set<Platform>, toolchain: String?, customCacheCommand: String?) -> SignalProducer<Bool, CarthageError> {
        if let cache = self.binariesCache(for: dependency, customCacheCommand: customCacheCommand) {
            return SwiftToolchain.swiftVersion(usingToolchain: toolchain)
                .mapError { error in CarthageError.internalError(description: error.description) }
                .flatMap(.concat) { localSwiftVersion -> SignalProducer<Bool, CarthageError> in
                    var lock: URLLock?
                    return cache.matchingBinary(
                        for: dependency,
                        pinnedVersion: pinnedVersion,
                        configuration: configuration,
                        platforms: platforms,
                        swiftVersion: localSwiftVersion,
                        eventObserver: self.projectEventsObserver,
                        lockTimeout: self.lockTimeout
                        )
                        .flatMap(.concat) { urlLock -> SignalProducer<(), CarthageError> in
                            lock = urlLock
                            if let url = urlLock?.url {
                                self.projectEventsObserver?.send(value: .installingBinaries(dependency, pinnedVersion.description))
                                return self.unarchiveAndCopyBinaryFrameworks(zipFile: url, dependency: dependency, pinnedVersion: pinnedVersion, configuration: configuration, swiftVersion: localSwiftVersion)
                            } else {
                                self.projectEventsObserver?.send(value: .skippedInstallingBinaries(dependency: dependency, error: nil))
                                return SignalProducer<(), CarthageError>.empty
                            }
                        }
                        .map { lock != nil }
                        .flatMapError { error in
                            if case .incompatibleFrameworkSwiftVersion = error, let url = lock?.url {
                                _ = try? FileManager.default.removeItem(at: url)
                            }
                            self.projectEventsObserver?.send(value: .skippedInstallingBinaries(dependency: dependency, error: error))
                            return SignalProducer(value: false)
                        }
                        .concat(value: false)
                        .take(first: 1)
                        .on(terminated: { lock?.unlock() })
            }
        } else {
            return SignalProducer(value: false)
        }
    }

    public func storeBinaries(for dependency: Dependency, frameworkNames: [String], pinnedVersion: PinnedVersion, configuration: String, toolchain: String?) -> SignalProducer<URL, CarthageError> {
        var tempDir: URL?

        return FileManager.default.reactive.createTemporaryDirectory()
            .flatMap(.merge) { tempDirectoryURL -> SignalProducer<URL, CarthageError> in
                tempDir = tempDirectoryURL
                return Archive.archiveFrameworks(frameworkNames: frameworkNames, dependencyName: dependency.name, directoryURL: self.directoryURL, customOutputPath: tempDirectoryURL.appendingPathComponent(dependency.name + ".framework.zip").path)
            }
            .flatMap(.merge) { archiveURL -> SignalProducer<URL, CarthageError> in
                return SwiftToolchain.swiftVersion(usingToolchain: toolchain)
                    .mapError { error in CarthageError.internalError(description: error.description) }
                    .flatMap(.merge) { swiftVersion -> SignalProducer<URL, CarthageError> in
                        self.projectEventsObserver?.send(value: .storingBinaries(dependency, pinnedVersion.description))
                        return AbstractBinariesCache.storeFile(at: archiveURL, for: dependency, version: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion, lockTimeout: self.lockTimeout, deleteSource: true)
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
                        return self.downloadBinary(dependency: dependency, pinnedVersion: pinnedVersion, binaryProject: binaryProject, configuration: configuration, platforms: platforms, swiftVersion: localSwiftVersion)
                    }
                    .flatMap(.concat) { urlLock -> SignalProducer<(), CarthageError> in
                        lock = urlLock
                        return self.unarchiveAndCopyBinaryFrameworks(zipFile: urlLock.url, dependency: dependency, pinnedVersion: pinnedVersion, configuration: configuration, swiftVersion: localSwiftVersion)
                    }
                    .on(failed: { error in
                        if case .incompatibleFrameworkSwiftVersion = error, let url = lock?.url {
                            _ = try? FileManager.default.removeItem(at: url)
                        }
                    })
                    .on(terminated: { lock?.unlock() })
            })
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
                        if isRepository {
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

                            // If we've already cloned the repo, check for the revision, possibly skipping an unnecessary fetch
                            if let commitish = commitish {
                                return SignalProducer.zip(
                                    Git.branchExistsInRepository(repositoryURL, pattern: commitish),
                                    Git.commitExistsInRepository(repositoryURL, revision: commitish)
                                    )
                                    .flatMap(.concat) { branchExists, commitExists -> SignalProducer<(ProjectEvent?, URLLock), CarthageError> in
                                        // If the given commitish is a branch, we should fetch.
                                        if branchExists || !commitExists {
                                            return fetchProducer()
                                        } else {
                                            return SignalProducer(value: (nil, urlLock))
                                        }
                                }
                            } else {
                                return fetchProducer()
                            }
                        } else {
                            // Either the directory didn't exist or it did but wasn't a git repository
                            // (Could happen if the process is killed during a previous directory creation)
                            // So we remove it, then clone
                            _ = try? fileManager.removeItem(at: repositoryURL)
                            return SignalProducer(value: (.cloning(dependency), urlLock))
                                .concat(
                                    Git.cloneRepository(remoteURL, repositoryURL)
                                        .then(SignalProducer<(ProjectEvent?, URLLock), CarthageError>.empty)
                            )
                        }
                }
            }.on(failed: { _ in
                lock?.unlock()
            }, interrupted: {
                lock?.unlock()
            })
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
    private func downloadBinary(dependency: Dependency, pinnedVersion: PinnedVersion, binaryProject: BinaryProject, configuration: String, platforms: Set<Platform>, swiftVersion: PinnedVersion) -> SignalProducer<URLLock, CarthageError> {
        let binariesCache: BinariesCache = BinaryProjectCache(binaryProjectDefinitions: [dependency: binaryProject])
        return binariesCache.matchingBinary(for: dependency, pinnedVersion: pinnedVersion, configuration: configuration, platforms: platforms, swiftVersion: swiftVersion, eventObserver: self.projectEventsObserver, lockTimeout: self.lockTimeout)
            .attemptMap({ urlLock -> Result<URLLock, CarthageError> in
                if let lock = urlLock {
                    return .success(lock)
                } else {
                    //This should not happen, the binaries cache should trigger a read failed error instead
                    return .failure(CarthageError.internalError(description: "Could not download binary file for dependency \(dependency.name) version \(pinnedVersion)"))
                }
            })
    }

    /// Creates symlink between the dependency checkouts and the root checkouts
    private func symlinkCheckoutPaths(
        for dependency: Dependency,
        version: PinnedVersion,
        withRepository repositoryURL: URL,
        atRootDirectory rootDirectoryURL: URL
        ) -> SignalProducer<(), CarthageError> {
        let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
        let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()
        let dependencyCheckoutsURL = dependencyURL.appendingPathComponent(carthageProjectCheckoutsPath, isDirectory: true).resolvingSymlinksInPath()
        let fileManager = FileManager.default

        return dependencySet(for: dependency, version: version)
            // file system objects which might conflict with symlinks
            .zip(with: Git.list(treeish: version.commitish, atPath: carthageProjectCheckoutsPath, inRepository: repositoryURL)
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
                    let subdirectoryPath = (carthageProjectCheckoutsPath as NSString).appendingPathComponent(name)
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

    /// Unzips the file at the given URL and copies the frameworks, DSYM and
    /// bcsymbolmap files into the corresponding folders for the project. This
    /// step will also check framework compatibility and create a version file
    /// for the given frameworks.
    private func unarchiveAndCopyBinaryFrameworks(
        zipFile: URL,
        dependency: Dependency,
        pinnedVersion: PinnedVersion,
        configuration: String,
        swiftVersion: PinnedVersion
        ) -> SignalProducer<(), CarthageError> {

        return SignalProducer<URL, CarthageError>(value: zipFile)
            .flatMap(.concat, Archive.unarchive(archive:))
            .flatMap(.concat) { tempDirectoryURL -> SignalProducer<(), CarthageError> in
                return self.installBinaries(sourceDirectoryURL: tempDirectoryURL,
                                                  dependency: dependency,
                                                  pinnedVersion: pinnedVersion,
                                                  configuration: configuration,
                                                  swiftVersion: swiftVersion)
                .on(terminated: { tempDirectoryURL.removeIgnoringErrors() })
        }
    }

    private func installBinaries(
        sourceDirectoryURL: URL,
        dependency: Dependency,
        pinnedVersion: PinnedVersion,
        configuration: String,
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
                        SignalProducer<URL, CarthageError>(value: frameworkSourceURL).moveFileURLsIntoDirectory(destinationDirectoryURL)
                    )
                    .then(
                        SignalProducer(value: frameworkDestinationURL)
                )
            }
            .collect()
            // Collect .bundle folders as well, for pure binaries or non-framework dependencies
            .flatMap(.merge) { frameworkURLs -> SignalProducer<[URL], CarthageError> in
                return Frameworks.bundlesInDirectory(sourceDirectoryURL)
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
                        return SignalProducer<URL, CarthageError>(value: sourceURL)
                            .moveFileURLsIntoDirectory(destinationURL)
                    }
                    .then(SignalProducer.init(value: frameworkURLs))
            }
            // Write the .version file
            .flatMap(.concat) { frameworkURLs -> SignalProducer<(), CarthageError> in

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
                        configuration: configuration
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
        configuration: String
        ) -> SignalProducer<(), CarthageError> {
        return VersionFile.createVersionFileForCommitish(commitish,
                                                         dependencyName: projectName,
                                                         configuration: configuration,
                                                         buildProducts: frameworkURLs,
                                                         rootDirectoryURL: self.directoryURL)
    }
}

private struct DependencyRef: Hashable {
    public let dependency: Dependency
    public let ref: String
}
