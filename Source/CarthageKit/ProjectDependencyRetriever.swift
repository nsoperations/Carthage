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
import SPMUtility

import struct Foundation.URL

public final class ProjectDependencyRetriever {

    private typealias CachedVersions = [Dependency: [PinnedVersion]]

    /// Caches versions to avoid expensive lookups, and unnecessary
    /// fetching/cloning.
    private var cachedVersions: CachedVersions = [:]
    private let cachedVersionsQueue = SerialProducerQueue(name: "org.carthage.Constants.Project.cachedVersionsQueue")

    private typealias CachedBinaryProjects = [URL: BinaryProject]

    // Cache the binary project definitions in memory to avoid redownloading during carthage operation
    private var cachedBinaryProjects: CachedBinaryProjects = [:]
    private let cachedBinaryProjectsQueue = SerialProducerQueue(name: "org.carthage.Constants.Project.cachedBinaryProjectsQueue")
    private let gitOperationQueue = SerialProducerQueue(name: "org.carthage.Constants.Project.gitOperationQueue")

    let projectEventsObserver: Signal<ProjectEvent, NoError>.Observer?
    var preferHTTPS = true
    var lockTimeout: Int = Constants.defaultLockTimeout
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
        return ProjectDependencyRetriever.cloneOrFetch(dependency: dependency, preferHTTPS: self.preferHTTPS, lockTimeout: self.lockTimeout, commitish: commitish)
            .on(value: { event, _ in
                if let event = event {
                    self.projectEventsObserver?.send(value: event)
                }
            })
            .map { _, url in url }
            .take(last: 1)
            .startOnQueue(cloneOrFetchQueue)
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

    /// Loads the dependencies for the given dependency, at the given version.
    public func dependencies(for dependency: Dependency, version: PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
        return self.dependencies(for: dependency, version: version, tryCheckoutDirectory: false)
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
            let cartfileFetch: SignalProducer<Cartfile, CarthageError> = cloneOrFetchDependency(dependency, commitish: revision)
                .flatMap(.concat) { repositoryURL in
                    return contentsOfFileInRepository(repositoryURL, Constants.Project.cartfilePath, revision: revision)
                }
                .flatMapError { _ in .empty }
                .attemptMap(Cartfile.from(string:))

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
        return cloneOrFetchDependency(dependency, commitish: reference)
            .flatMap(.concat) { repositoryURL in
                return resolveTagInRepository(repositoryURL, reference)
                    .map { _ in
                        // If the reference is an exact tag, resolves it to the tag.
                        return PinnedVersion(reference)
                    }
                    .flatMapError { _ in
                        return resolveReferenceInRepository(repositoryURL, reference)
                            .map(PinnedVersion.init)
                }
        }
    }

    /// Sends all versions available for the given project.
    ///
    /// This will automatically clone or fetch the project's repository as
    /// necessary.
    public func versions(for dependency: Dependency) -> SignalProducer<PinnedVersion, CarthageError> {
        let fetchVersions: SignalProducer<PinnedVersion, CarthageError>

        switch dependency {
        case .git, .gitHub:
            fetchVersions = cloneOrFetchDependency(dependency)
                .flatMap(.merge) { repositoryURL in listTags(repositoryURL) }
                .map { PinnedVersion($0) }

        case let .binary(binary):
            fetchVersions = downloadBinaryFrameworkDefinition(binary: binary)
                .flatMap(.concat) { binaryProject -> SignalProducer<PinnedVersion, CarthageError> in
                    return SignalProducer(binaryProject.versions.keys)
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

    /// Downloads any binaries and debug symbols that may be able to be used
    /// instead of a repository checkout.
    ///
    /// Sends the URL to each downloaded zip, after it has been moved to a
    /// less temporary location.
    public func downloadMatchingBinaries(
        for dependency: Dependency,
        pinnedVersion: PinnedVersion,
        fromRepository repository: Repository,
        client: Client
        ) -> SignalProducer<URL, CarthageError> {
        return client.execute(repository.release(forTag: pinnedVersion.commitish))
            .map { _, release in release }
            .filter { release in
                return !release.isDraft && !release.assets.isEmpty
            }
            .flatMapError { error -> SignalProducer<Release, CarthageError> in
                switch error {
                case .doesNotExist:
                    return .empty

                case let .apiError(_, _, error):
                    // Log the GitHub API request failure, not to error out,
                    // because that should not be fatal error.
                    self.projectEventsObserver?.send(value: .skippedDownloadingBinaries(dependency, error.message))
                    return .empty

                default:
                    return SignalProducer(error: .gitHubAPIRequestFailed(error))
                }
            }
            .on(value: { release in
                self.projectEventsObserver?.send(value: .downloadingBinaries(dependency, release.nameWithFallback))
            })
            .flatMap(.concat) { release -> SignalProducer<URL, CarthageError> in
                return SignalProducer<Release.Asset, CarthageError>(release.assets)
                    .filter { asset in
                        if asset.name.range(of: Constants.Project.binaryAssetPattern) == nil {
                            return false
                        }
                        return Constants.Project.binaryAssetContentTypes.contains(asset.contentType)
                    }
                    .flatMap(.concat) { asset -> SignalProducer<URL, CarthageError> in
                        let fileURL = self.fileURLToCachedBinary(dependency, release, asset)

                        if FileManager.default.fileExists(atPath: fileURL.path) {
                            return SignalProducer(value: fileURL)
                        } else {
                            return client.download(asset: asset)
                                .mapError(CarthageError.gitHubAPIRequestFailed)
                                .flatMap(.concat) { downloadURL in self.cacheDownloadedBinary(downloadURL, toURL: fileURL) }
                        }
                }
        }
    }

    /// Downloads the binary only framework file. Sends the URL to each downloaded zip, after it has been moved to a
    /// less temporary location.
    public func downloadBinary(dependency: Dependency, version: Version, url: URL) -> SignalProducer<URL, CarthageError> {
        let fileName = url.lastPathComponent
        let fileURL = fileURLToCachedBinaryDependency(dependency, version, fileName)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return SignalProducer(value: fileURL)
        } else {
            return URLSession.shared.reactive.download(with: URLRequest(url: url))
                .on(started: {
                    self.projectEventsObserver?.send(value: .downloadingBinaries(dependency, version.description))
                })
                .mapError { CarthageError.readFailed(url, $0 as NSError) }
                .flatMap(.concat) { downloadURL, _ in self.cacheDownloadedBinary(downloadURL, toURL: fileURL) }
        }
    }

    /// Checks out the given dependency into its intended working directory,
    /// cloning it first if need be.
    public func checkoutOrCloneDependency(
        _ dependency: Dependency,
        version: PinnedVersion,
        submodulesByPath: [String: Submodule]
        ) -> SignalProducer<(), CarthageError> {
        let revision = version.commitish
        return cloneOrFetchDependency(dependency, commitish: revision)
            .flatMap(.merge) { repositoryURL -> SignalProducer<(), CarthageError> in
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
                    return addSubmoduleToRepository(self.directoryURL, submodule, GitURL(repositoryURL.path))
                        .startOnQueue(self.gitOperationQueue)
                        .then(symlinkCheckoutPaths)
                } else {
                    return checkoutRepositoryToDirectory(repositoryURL, workingDirectoryURL, revision: revision)
                        // For checkouts of “ideally bare” repositories of `dependency`, we add its submodules by cloning ourselves, after symlinking.
                        .then(symlinkCheckoutPaths)
                        .then(
                            submodulesInRepository(repositoryURL, revision: revision)
                                .flatMap(.merge) {
                                    cloneSubmoduleInWorkingDirectory($0, workingDirectoryURL)
                            }
                    )
                }
            }
            .on(started: {
                self.projectEventsObserver?.send(value: .checkingOut(dependency, revision))
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
        lockTimeout: Int = Constants.defaultLockTimeout,
        destinationURL: URL = Constants.Dependency.repositoriesURL,
        commitish: String? = nil
        ) -> SignalProducer<(ProjectEvent?, URL), CarthageError> {
        let fileManager = FileManager.default
        let repositoryURL = repositoryFileURL(for: dependency, baseURL: destinationURL)
        var lockFileURL: URL?

        return SignalProducer {
            Result(at: destinationURL, attempt: {
                try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
                return repositoryURL
            })
            }
            .flatMap(.merge) { (repositoryURL: URL) -> SignalProducer<URL, CarthageError> in
                return ProjectDependencyRetriever.obtainLock(repositoryURL: repositoryURL, timeout: lockTimeout)
            }
            .map { fileURL in
                lockFileURL = fileURL
                return dependency.gitURL(preferHTTPS: preferHTTPS)!
            }
            .flatMap(.merge) { (remoteURL: GitURL) -> SignalProducer<(ProjectEvent?, URL), CarthageError> in
                return isGitRepository(repositoryURL)
                    .flatMap(.merge) { isRepository -> SignalProducer<(ProjectEvent?, URL), CarthageError> in
                        if isRepository {
                            let fetchProducer: () -> SignalProducer<(ProjectEvent?, URL), CarthageError> = {
                                guard FetchCache.needsFetch(forURL: remoteURL) else {
                                    return SignalProducer(value: (nil, repositoryURL))
                                }

                                return SignalProducer(value: (.fetching(dependency), repositoryURL))
                                    .concat(
                                        fetchRepository(repositoryURL, remoteURL: remoteURL, refspec: "+refs/heads/*:refs/heads/*")
                                            .then(SignalProducer<(ProjectEvent?, URL), CarthageError>.empty)
                                )
                            }

                            // If we've already cloned the repo, check for the revision, possibly skipping an unnecessary fetch
                            if let commitish = commitish {
                                return SignalProducer.zip(
                                    branchExistsInRepository(repositoryURL, pattern: commitish),
                                    commitExistsInRepository(repositoryURL, revision: commitish)
                                    )
                                    .flatMap(.concat) { branchExists, commitExists -> SignalProducer<(ProjectEvent?, URL), CarthageError> in
                                        // If the given commitish is a branch, we should fetch.
                                        if branchExists || !commitExists {
                                            return fetchProducer()
                                        } else {
                                            return SignalProducer(value: (nil, repositoryURL))
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
                            return SignalProducer(value: (.cloning(dependency), repositoryURL))
                                .concat(
                                    cloneRepository(remoteURL, repositoryURL)
                                        .then(SignalProducer<(ProjectEvent?, URL), CarthageError>.empty)
                            )
                        }
                }
            }.on(terminated: {
                if let lockFileURL = lockFileURL {
                    ProjectDependencyRetriever.releaseLock(lockFileURL: lockFileURL)
                }
            })
    }

    private static func obtainLock(repositoryURL: URL, timeout: Int) -> SignalProducer<URL, CarthageError> {
        //shlock -f lockfile
        let repositoryParentURL = repositoryURL.deletingLastPathComponent()
        let repositoryName = repositoryURL.lastPathComponent
        let lockFileURL = repositoryParentURL.appendingPathComponent(".\(repositoryName).lock")
        let processId = String(ProcessInfo.processInfo.processIdentifier)
        let taskDescription = Task("/usr/bin/shlock", arguments: ["-f", lockFileURL.path, "-p", processId])
        let retryInterval = 1
        let retryCount = timeout == 0 ? Int.max : timeout / retryInterval
        return taskDescription.launch()
            .ignoreTaskData()
            .retry(upTo: retryCount, interval: TimeInterval(retryInterval), on: QueueScheduler(qos: .default))
            .mapError { _ in return .lockError(url: repositoryURL, timeout: timeout) }
            .map { _ in return lockFileURL }
    }

    private static func releaseLock(lockFileURL: URL) {
        _ = try? FileManager.default.removeItem(at: lockFileURL)
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
            .zip(with: list(treeish: version.commitish, atPath: carthageProjectCheckoutsPath, inRepository: repositoryURL)
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
                    let linkDestinationPath = relativeLinkDestination(for: dependency, subdirectory: subdirectoryPath)

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

    /// Returns the file URL at which the given project's repository will be
    /// located.
    private static func repositoryFileURL(for dependency: Dependency, baseURL: URL) -> URL {
        return baseURL.appendingPathComponent(dependency.name, isDirectory: true)
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

    /// Constructs a file URL to where the binary corresponding to the given
    /// arguments should live.
    private func fileURLToCachedBinary(_ dependency: Dependency, _ release: Release, _ asset: Release.Asset) -> URL {
        // ~/Library/Caches/org.carthage.CarthageKit/binaries/ReactiveCocoa/v2.3.1/1234-ReactiveCocoa.framework.zip
        return Constants.Dependency.assetsURL.appendingPathComponent("\(dependency.name)/\(release.tag)/\(asset.id)-\(asset.name)", isDirectory: false)
    }

    /// Constructs a file URL to where the binary only framework download should be cached
    private func fileURLToCachedBinaryDependency(_ dependency: Dependency, _ semanticVersion: Version, _ fileName: String) -> URL {
        // ~/Library/Caches/org.carthage.CarthageKit/binaries/MyBinaryProjectFramework/2.3.1/MyBinaryProject.framework.zip
        return Constants.Dependency.assetsURL.appendingPathComponent("\(dependency.name)/\(semanticVersion)/\(fileName)")
    }

}
