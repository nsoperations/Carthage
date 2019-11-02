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

extension ProjectDependencyRetrieverNonReactive: DependencyRetrieverProtocol {

    public func dependencies(
        for dependency: Dependency,
        version: PinnedVersion,
        tryCheckoutDirectory: Bool
        ) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
        return SignalProducer.init(error: .internalError(description: "Not implemented"))
    }

    public func resolvedGitReference(_ dependency: Dependency, reference: String) -> SignalProducer<PinnedVersion, CarthageError> {
        return SignalProducer.init(error: .internalError(description: "Not implemented"))
    }

    public func versions(for dependency: Dependency) -> SignalProducer<PinnedVersion, CarthageError> {
        return SignalProducer.init(error: .internalError(description: "Not implemented"))
    }
}

public final class ProjectDependencyRetrieverNonReactive {

    /// Caches versions to avoid expensive lookups, and unnecessary
    /// fetching/cloning.
    private let cachedVersions = Cache<Dependency, [PinnedVersion]>()
    private let cachedGitReferences = Cache<DependencyRef, PinnedVersion>()
    private let cachedBinaryProjects = Cache<BinaryURL, BinaryProject>()

    let projectEventsObserver: Signal<ProjectEvent, NoError>.Observer?
    var preferHTTPS = true
    var lockTimeout: Int?
    var useSubmodules = false
    var netrc: Netrc? = nil
    let directoryURL: URL

    public init(directoryURL: URL, projectEventsObserver: Signal<ProjectEvent, NoError>.Observer? = nil) {
        self.directoryURL = directoryURL
        self.projectEventsObserver = projectEventsObserver
    }

    /// Clones the given dependency to the global repositories folder, or fetches
    /// inside it if it has already been cloned.
    ///
    /// Returns a signal which will send the URL to the repository's folder on
    /// disk once cloning or fetching has completed.
    public func cloneOrFetchDependency(_ dependency: Dependency, commitish: String? = nil) throws -> URL {
        return try cloneOrFetchDependencyLocked(dependency, commitish: commitish) { $0 }
    }

    /// Produces the sub dependencies of the given dependency. Uses the checked out directory if able
    public func dependencySet(for dependency: Dependency, version: PinnedVersion, resolvedCartfile: ResolvedCartfile) throws -> Set<Dependency> {
        return try self.dependencies(for: dependency, version: version, tryCheckoutDirectory: true)
            .reduce(into: Set<Dependency>(), { set, entry in
                // This is to ensure that dependencies with the same name resolve to the one in the Cartfile.resolved
                let effectiveDependency: Dependency = resolvedCartfile.dependency(for: entry.key.name) ?? entry.key
                set.insert(effectiveDependency)
            })
    }

    public func transitiveDependencySet(for dependency: Dependency, version: PinnedVersion, resolvedCartfile: ResolvedCartfile) throws -> Set<Dependency> {
        let dependencyVersions = resolvedCartfile.dependencies
        var resultSet = Set<Dependency>()
        var unhandledSet = try self.dependencySet(for: dependency, version: version, resolvedCartfile: resolvedCartfile)

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
            let nextSet = try self.dependencySet(for: nextDependency, version: nextVersion, resolvedCartfile: resolvedCartfile)
            for transitiveDependency in nextSet where !resultSet.contains(transitiveDependency) {
                unhandledSet.insert(transitiveDependency)
            }
        }
        return resultSet
    }

    /// Finds all the transitive dependencies for the dependencies to checkout.
    public func transitiveDependencySet(
        resolvedCartfile: ResolvedCartfile,
        includedDependencyNames: Set<String>? = nil
        ) throws -> Set<Dependency> {

        let filteredDependencies: [DependencyDefinition] = resolvedCartfile.dependencies.filter { dep, _ in includedDependencyNames?.contains(dep.name) ?? true }
        return try filteredDependencies.reduce(into: Set<Dependency>()) { (set, definition) in
            try self.dependencies(for: definition.key, version: definition.value, tryCheckoutDirectory: true).forEach {
                set.insert($0.key)
            }
        }
    }

    /// Loads the dependencies for the given dependency, at the given version. Optionally can attempt to read from the Checkout directory
    public func dependencies(
        for dependency: Dependency,
        version: PinnedVersion,
        tryCheckoutDirectory: Bool
        ) throws -> [DependencyRequirement] {

        switch dependency {
        case .git, .gitHub:
            let revision = version.commitish
            let cartfile: Cartfile?
            let dependencyURL = self.directoryURL.appendingPathComponent(dependency.relativePath)

            if tryCheckoutDirectory && dependencyURL.isExistingDirectory {
                let cartfileURL = Cartfile.url(in: dependencyURL)
                if cartfileURL.isExistingFile {
                    cartfile = try Cartfile.from(fileURL: cartfileURL).get()
                }
            } else {
                cartfile = try cloneOrFetchDependencyLocked(dependency, commitish: revision) { url -> Cartfile? in
                    if case let .success(string) = Git.contentsOfFileInRepository(url, Constants.Project.cartfilePath, revision: revision).only() {
                        return try Cartfile.from(string: string).get()
                    }
                    return nil
                }
            }
            return cartfile?.dependencies.map { $0 } ?? []

        case .binary:
            // Binary-only frameworks do not support dependencies
            return []
        }
    }

    /// Attempts to resolve a Git reference to a version.
    public func resolvedGitReference(_ dependency: Dependency, reference: String) throws -> PinnedVersion {
        return try self.cachedGitReferences.getValue(key: DependencyRef(dependency: dependency, ref: reference)) { dependencyRef in
            return try cloneOrFetchDependencyLocked(dependency, commitish: reference) { repositoryURL in
                return try Git.resolveReferenceInRepository(repositoryURL, reference)
                    .only()
                    .map(PinnedVersion.init)
                    .get()
            }
        }
    }

    /// Sends all versions available for the given project.
    ///
    /// This will automatically clone or fetch the project's repository as
    /// necessary.
    public func versions(for dependency: Dependency) throws -> [PinnedVersion] {
        let pinnedVersions = try self.cachedVersions.getValue(key: dependency) { dependency in
            switch dependency {
            case .git, .gitHub:
                return try cloneOrFetchDependencyLocked(dependency) { repositoryURL -> [PinnedVersion] in
                    return try Git.listTags(repositoryURL).filterMap { tag -> PinnedVersion? in
                        let pinnedVersion = PinnedVersion(tag)
                        return pinnedVersion.isSemantic ? pinnedVersion : nil
                        }.collect().only().get()
                }

            case let .binary(binaryURL):
                return try downloadBinaryFrameworkDefinition(binaryURL: binaryURL).versions
            }
        }

        if pinnedVersions.isEmpty {
            throw CarthageError.taggedVersionNotFound(dependency)
        }

        return pinnedVersions
    }

    public func downloadBinaryFrameworkDefinition(binaryURL: BinaryURL) throws -> BinaryProject {
        return try self.cachedBinaryProjects.getValue(key: binaryURL) { binary in
            self.projectEventsObserver?.send(value: .downloadingBinaryFrameworkDefinition(.binary(binary), binary.url))
            return try URLSession.shared.reactive.data(with: URLRequest(url: binary.url, netrc: self.netrc))
                .only()
                .mapError {
                    return CarthageError.readFailed(binary.url, $0 as NSError)
                }
                .flatMap { data, response -> Result<BinaryProject, CarthageError> in
                    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                        return .failure(CarthageError.httpError(statusCode: httpResponse.statusCode))
                    }
                    return BinaryProject.from(jsonData: data).mapError { error in
                        return CarthageError.invalidBinaryJSON(binary.url, error)
                    }
                }
                .get()
        }
    }

    /// Checks out the given dependency into its intended working directory,
    /// cloning it first if need be.
    public func checkoutOrCloneDependency(
        _ dependency: Dependency,
        version: PinnedVersion,
        submodulesByPath: [String: Submodule],
        resolvedCartfile: ResolvedCartfile) throws {
        let revision = version.commitish

        try cloneOrFetchDependencyLocked(dependency, commitish: revision) { repositoryURL -> () in

            self.projectEventsObserver?.send(value: .checkingOut(dependency, revision))

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

            let symlinkCheckoutPaths = self.symlinkCheckoutPaths(for: dependency, version: version, withRepository: repositoryURL, atRootDirectory: self.directoryURL, resolvedCartfile: resolvedCartfile)

            if let submodule = submodule {
                // In the presence of `submodule` for `dependency` — before symlinking, (not after) — add submodule and its submodules:
                // `dependency`, subdependencies that are submodules, and non-Carthage-housed submodules.
                try Git.addSubmoduleToRepository(self.directoryURL, submodule, GitURL(repositoryURL.path))
                    .then(symlinkCheckoutPaths)
                    .wait()
                    .get()
            } else {
                try Git.checkoutRepositoryToDirectory(repositoryURL, workingDirectoryURL, revision: revision)
                    // For checkouts of “ideally bare” repositories of `dependency`, we add its submodules by cloning ourselves, after symlinking.
                    .then(symlinkCheckoutPaths)
                    .then(
                        Git.submodulesInRepository(repositoryURL, revision: revision)
                            .flatMap(.merge) {
                                Git.cloneSubmoduleInWorkingDirectory($0, workingDirectoryURL)
                        }
                )
                .wait()
                .get()
            }

        }
    }

    /// Clones the given project to the given destination URL (defaults to the global
    /// repositories folder), or fetches inside it if it has already been cloned.
    /// Optionally takes a commitish to check for prior to fetching.
    ///
    /// Returns a signal which will send the operation type once started, and
    /// the URL to where the repository's folder will exist on disk, then complete
    /// when the operation completes.
//    public static func cloneOrFetch(
//        dependency: Dependency,
//        preferHTTPS: Bool,
//        lockTimeout: Int? = nil,
//        destinationURL: URL = Constants.Dependency.repositoriesURL,
//        commitish: String? = nil
//        ) throws -> URL {
//        return try cloneOrFetchLocked(dependency: dependency, preferHTTPS: preferHTTPS, lockTimeout: lockTimeout) { $0 }
//    }

    /// Installs binaries and debug symbols for the given project, if available.
    ///
    /// Sends a boolean indicating whether binaries were installed.
    public func installBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, platforms: Set<Platform>, toolchain: String?, customCacheCommand: String?) throws -> Bool {
        if let cache = self.binariesCache(for: dependency, customCacheCommand: customCacheCommand) {
            return try SwiftToolchain.swiftVersion(usingToolchain: toolchain)
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
                        lockTimeout: self.lockTimeout,
                        netrc: self.netrc
                        )
                        .flatMap(.concat) { urlLock -> SignalProducer<Bool, CarthageError> in
                            lock = urlLock
                            if let url = urlLock?.url {
                                self.projectEventsObserver?.send(value: .installingBinaries(dependency, pinnedVersion.description))
                                return self.unarchiveAndCopyBinaryFrameworks(zipFile: url, dependency: dependency, pinnedVersion: pinnedVersion, configuration: configuration, swiftVersion: localSwiftVersion)
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
                .only()
                .get()
        } else {
            return false
        }
    }

    public func storeBinaries(for dependency: Dependency, frameworkNames: [String], pinnedVersion: PinnedVersion, configuration: String, toolchain: String?) throws -> URL {
        var tempDir: URL?
        return try FileManager.default.reactive.createTemporaryDirectory()
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
            .only()
            .get()
    }

    public func installBinariesForBinaryProject(
        binary: BinaryURL,
        pinnedVersion: PinnedVersion,
        configuration: String,
        platforms: Set<Platform>,
        toolchain: String?
        ) throws {

        let dependency = Dependency.binary(binary)

        try SwiftToolchain.swiftVersion(usingToolchain: toolchain)
            .mapError { error in CarthageError.internalError(description: error.description) }
            .flatMap(.concat, { localSwiftVersion -> SignalProducer<(), CarthageError> in
                var lock: URLLock?
                return self.downloadBinaryFrameworkDefinition(binary: binary)
                    .flatMap(.concat) { binaryProject in
                        return self.downloadBinary(dependency: dependency, pinnedVersion: pinnedVersion, binaryProject: binaryProject, configuration: configuration, platforms: platforms, swiftVersion: localSwiftVersion)
                    }
                    .flatMap(.concat) { urlLock -> SignalProducer<(), CarthageError> in
                        lock = urlLock
                        self.projectEventsObserver?.send(value: .installingBinaries(dependency, pinnedVersion.description))
                        return self.unarchiveAndCopyBinaryFrameworks(zipFile: urlLock.url, dependency: dependency, pinnedVersion: pinnedVersion, configuration: configuration, swiftVersion: localSwiftVersion)
                    }
                    .on(failed: { error in
                        if case .incompatibleFrameworkSwiftVersion = error, let url = lock?.url {
                            _ = try? FileManager.default.removeItem(at: url)
                        }
                    })
                    .on(terminated: { lock?.unlock() })
            })
            .wait()
            .get()
    }

    // MARK: - Private methods

    private func cloneOrFetchDependencyLocked<T>(_ dependency: Dependency, commitish: String? = nil, perform: (URL) throws -> T) throws -> T {
        return try ProjectDependencyRetrieverNonReactive.cloneOrFetchLocked(dependency: dependency, preferHTTPS: self.preferHTTPS, lockTimeout: self.lockTimeout, commitish: commitish, observer: { self.projectEventsObserver?.send(value: $0) }, perform: perform)
    }

    private static func cloneOrFetchLocked<T>(
        dependency: Dependency,
        preferHTTPS: Bool,
        lockTimeout: Int?,
        destinationURL: URL = Constants.Dependency.repositoriesURL,
        commitish: String? = nil,
        observer: ((ProjectEvent) -> Void)? = nil,
        perform: (URL) throws -> T
        ) throws -> T {

        let repositoryURL = Dependencies.repositoryFileURL(for: dependency, baseURL: destinationURL)

        return try URLLock(url: repositoryURL).locked(timeout: lockTimeout) { url in
            guard let remoteURL = dependency.gitURL(preferHTTPS: preferHTTPS) else {
                fatalError("Non git dependency supplied to method where git was expected: \(dependency)")
            }

            let isRepository = try Git.isGitRepository(repositoryURL).getOnly()

            fetch: do {
                if isRepository {

                    // If we've already cloned the repo, check for the revision, possibly skipping an unnecessary fetch
                    if let commitish = commitish {
                        let branchExists = try Git.branchExistsInRepository(repositoryURL, pattern: commitish).getOnly()
                        let commitExists = try Git.commitExistsInRepository(repositoryURL, revision: commitish).getOnly()

                        // If the given commitish is a branch, we should fetch.
                        if !branchExists && commitExists {
                            break fetch
                        }
                    }

                    guard Git.FetchCache.needsFetch(forURL: remoteURL) else {
                        break fetch
                    }

                    observer?(.fetching(dependency))
                    try Git.fetchRepository(repositoryURL, remoteURL: remoteURL, refspec: "+refs/heads/*:refs/heads/*").getOnly()
                } else {
                    repositoryURL.removeIgnoringErrors()
                    observer?(.cloning(dependency))
                    try Git.cloneRepository(remoteURL, repositoryURL).getOnly()
                }
            }

            return try perform(url)
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
    private func downloadBinary(dependency: Dependency, pinnedVersion: PinnedVersion, binaryProject: BinaryProject, configuration: String, platforms: Set<Platform>, swiftVersion: PinnedVersion) -> SignalProducer<URLLock, CarthageError> {
        let binariesCache: BinariesCache = BinaryProjectCache(binaryProjectDefinitions: [dependency: binaryProject])
        return binariesCache.matchingBinary(for: dependency, pinnedVersion: pinnedVersion, configuration: configuration, platforms: platforms, swiftVersion: swiftVersion, eventObserver: self.projectEventsObserver, lockTimeout: self.lockTimeout, netrc: self.netrc)
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
        atRootDirectory rootDirectoryURL: URL,
        resolvedCartfile: ResolvedCartfile
        ) -> SignalProducer<(), CarthageError> {
        let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
        let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()
        let dependencyCheckoutsURL = dependencyURL.appendingPathComponent(Constants.checkoutsPath, isDirectory: true).resolvingSymlinksInPath()
        let fileManager = FileManager.default

        return self.recursiveDependencySet(for: dependency, version: version, resolvedCartfile: resolvedCartfile)
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
                return self.moveBinaries(sourceDirectoryURL: tempDirectoryURL,
                                         dependency: dependency,
                                         pinnedVersion: pinnedVersion,
                                         configuration: configuration,
                                         swiftVersion: swiftVersion)
                    .on(terminated: { tempDirectoryURL.removeIgnoringErrors() })
        }
    }

    private func moveBinaries(
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
