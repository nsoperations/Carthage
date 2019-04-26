import Foundation
import Result
import Tentacle
import ReactiveSwift
import ReactiveTask
import SPMUtility

import struct Foundation.URL

/// Cache for binary builds
protocol BinariesCache {

    func matchingBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: Version, cacheBaseURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock, CarthageError>
    
}

extension BinariesCache {
    fileprivate static func fileURL(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: Version?, fileName: String? = nil, cacheBaseURL: URL) -> URL {

        // Try to parse the semantic version out of the Swift version string
        let swiftVersionString: String = swiftVersion?.description ?? "Other"
        let versionString = pinnedVersion.description
        let effectiveFileName = fileName ?? dependency.name + ".framework.zip"
        return cacheBaseURL.appendingPathComponent("\(swiftVersionString)/\(dependency.name)/\(versionString)/\(configuration)/\(effectiveFileName)")
    }
}

class BinaryProjectCache: BinariesCache {
    
    let binaryProjectDefinitions: [Dependency: BinaryProject]
    
    init(binaryProjectDefinitions: [Dependency: BinaryProject]) {
        self.binaryProjectDefinitions = binaryProjectDefinitions
    }
    
    func matchingBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: Version, cacheBaseURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock, CarthageError> {
        
        guard let binaryProject = self.binaryProjectDefinitions[dependency], let sourceURL = binaryProject.binaryURL(for: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion) else {

            let error: CarthageError
            if let semanticVersion = pinnedVersion.semanticVersion {
                error = CarthageError.requiredVersionNotFound(dependency, VersionSpecifier.exactly(semanticVersion))
            } else {
                error = CarthageError.requiredVersionNotFound(dependency, VersionSpecifier.gitReference(pinnedVersion.commitish))
            }

            return SignalProducer<URLLock, CarthageError>(error: error)
        }
        
        return BinaryProjectCache.downloadBinary(dependency: dependency, version: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion, url: sourceURL, cacheBaseURL: cacheBaseURL, eventObserver: eventObserver, lockTimeout: lockTimeout)
    }
    
    /// Downloads the binary only framework file. Sends the URL to each downloaded zip, after it has been moved to a
    /// less temporary location.
    private static func downloadBinary(dependency: Dependency, version: PinnedVersion, configuration: String, swiftVersion: Version, url: URL, cacheBaseURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock, CarthageError> {
        let fileName = url.lastPathComponent
        let fileURL = BinaryProjectCache.fileURL(for: dependency, pinnedVersion: version, configuration: configuration, swiftVersion: swiftVersion, fileName: fileName, cacheBaseURL: cacheBaseURL)
        return URLLock.lockReactive(url: fileURL, timeout: lockTimeout)
            .flatMap(.merge) { (urlLock: URLLock) -> SignalProducer<URLLock, CarthageError> in
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    return SignalProducer(value: urlLock)
                } else {
                    let urlRequest = URLRequest(url: url)
                    return URLSession.shared.reactive.download(with: urlRequest)
                        .on(started: {
                            eventObserver?.send(value: .downloadingBinaries(dependency, version.description))
                        })
                        .mapError { CarthageError.readFailed(url, $0 as NSError) }
                        .flatMap(.concat) { result -> SignalProducer<URLLock, CarthageError> in
                            let downloadURL = result.0
                            return Files.moveFile(from: downloadURL, to: fileURL)
                                .then(SignalProducer<URLLock, CarthageError>(value: urlLock))
                    }
                }
        }
    }
}

class GitHubBinariesCache: BinariesCache {

    let repository: Repository
    let client: Client

    init(repository: Repository, client: Client) {
        self.repository = repository
        self.client = client
    }

    func matchingBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: Version, cacheBaseURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock, CarthageError> {
        return GitHubBinariesCache.downloadMatchingBinaries(for: dependency, pinnedVersion: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion, cacheBaseURL: cacheBaseURL, fromRepository: self.repository, client: self.client, lockTimeout: lockTimeout, eventObserver: eventObserver)
            .flatMapError { [client, repository] error -> SignalProducer<URLLock, CarthageError> in
                if !client.isAuthenticated {
                    return SignalProducer(error: error)
                }
                return GitHubBinariesCache.downloadMatchingBinaries(
                    for: dependency,
                    pinnedVersion: pinnedVersion,
                    configuration: configuration,
                    swiftVersion: swiftVersion,
                    cacheBaseURL: cacheBaseURL,
                    fromRepository: repository,
                    client: Client(server: client.server, isAuthenticated: false),
                    lockTimeout: lockTimeout,
                    eventObserver: eventObserver
                )
        }
    }

    private static func downloadMatchingBinaries(
        for dependency: Dependency,
        pinnedVersion: PinnedVersion,
        configuration: String,
        swiftVersion: Version,
        cacheBaseURL: URL,
        fromRepository repository: Repository,
        client: Client,
        lockTimeout: Int?,
        eventObserver: Signal<ProjectEvent, NoError>.Observer?
        ) -> SignalProducer<URLLock, CarthageError> {
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
                    eventObserver?.send(value: .skippedDownloadingBinaries(dependency, error.message))
                    return .empty

                default:
                    return SignalProducer(error: .gitHubAPIRequestFailed(error))
                }
            }
            .on(value: { release in
                eventObserver?.send(value: .downloadingBinaries(dependency, release.nameWithFallback))
            })
            .flatMap(.concat) { release -> SignalProducer<URLLock, CarthageError> in
                return SignalProducer<Release.Asset, CarthageError>(release.assets)
                    .filter { asset in
                        if asset.name.range(of: Constants.Project.binaryAssetPattern) == nil {
                            return false
                        }
                        return Constants.Project.binaryAssetContentTypes.contains(asset.contentType)
                    }
                    .flatMap(.concat) { asset -> SignalProducer<(URLLock, Release.Asset), CarthageError> in
                        let fileName = "\(asset.id.string)-\(asset.name)"

                        //No support for specific swift version with Github API
                        let fileURL = GitHubBinariesCache.fileURL(for: dependency, pinnedVersion: PinnedVersion(release.tag), configuration: configuration, swiftVersion: nil, fileName: fileName, cacheBaseURL: cacheBaseURL)
                        return URLLock.lockReactive(url: fileURL, timeout: lockTimeout).map { urlLock in
                            return (urlLock, asset)
                        }
                    }
                    .flatMap(.concat) { (urlLock, asset) -> SignalProducer<URLLock, CarthageError> in
                        let fileURL = urlLock.url
                        if FileManager.default.fileExists(atPath: fileURL.path) {
                            return SignalProducer(value: urlLock)
                        } else {
                            return client.download(asset: asset)
                                .mapError(CarthageError.gitHubAPIRequestFailed)
                                .flatMap(.concat) { downloadURL in
                                    Files.moveFile(from: downloadURL, to: fileURL)
                                        .then(SignalProducer<URLLock, CarthageError>(value: urlLock))
                            }
                        }
                }
        }
    }
}

class ExternalTaskBinariesCache: BinariesCache {

    let taskLaunchPath: String

    init(taskLaunchPath: String) {
        self.taskLaunchPath = taskLaunchPath
    }

    func matchingBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: Version, cacheBaseURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock, CarthageError> {
        let fileURL = GitHubBinariesCache.fileURL(for: dependency, pinnedVersion: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion, cacheBaseURL: cacheBaseURL)
        return URLLock.lockReactive(url: fileURL, timeout: lockTimeout)
            .flatMap(.merge) { (urlLock: URLLock) -> SignalProducer<URLLock, CarthageError> in
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    return SignalProducer(value: urlLock)
                } else {
                    let versionString = pinnedVersion.description
                    let task = Task(self.taskLaunchPath, arguments: [dependency.name, versionString, configuration, swiftVersion.description, fileURL.path])
                    return task.launch()
                        .mapError(CarthageError.taskError)
                        .on(started: {
                            eventObserver?.send(value: .downloadingBinaries(dependency, versionString))
                        })
                        .then(SignalProducer<URLLock, CarthageError>(value: urlLock))
                }
        }
    }
}
