import Foundation
import Result
import Tentacle
import ReactiveSwift
import ReactiveTask
import SPMUtility

import struct Foundation.URL

/// Cache for binary builds
protocol BinariesCache {
    
    func matchingBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: PinnedVersion, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock?, CarthageError>

}

extension BinariesCache {

    static func fileURL(for dependency: Dependency, version: PinnedVersion, configuration: String, swiftVersion: PinnedVersion) -> URL {

        // Try to parse the semantic version out of the Swift version string
        let cacheBaseURL = Constants.Dependency.assetsURL
        let swiftVersionString: String = swiftVersion.description
        let versionString = version.description
        let fileName = dependency.name + ".framework.zip"
        return cacheBaseURL.appendingPathComponent("\(swiftVersionString)/\(dependency.name)/\(versionString)/\(configuration)/\(fileName)")
    }

    static func storeFile(at fileURL: URL, for dependency: Dependency, version: PinnedVersion, configuration: String, swiftVersion: PinnedVersion, lockTimeout: Int?, deleteSource: Bool = false) -> SignalProducer<URL, CarthageError> {
        let destinationURL = AbstractBinariesCache.fileURL(for: dependency, version: version, configuration: configuration, swiftVersion: swiftVersion)
        var lock: URLLock?
        return URLLock.lockReactive(url: destinationURL, timeout: lockTimeout)
            .flatMap(.merge) { urlLock -> SignalProducer<URL, CarthageError> in
                lock = urlLock
                return deleteSource ? Files.moveFile(from: fileURL, to: urlLock.url) : Files.copyFile(from: fileURL, to: urlLock.url)
            }
            .on(terminated: {
                lock?.unlock()
            })
    }
}

class AbstractBinariesCache: BinariesCache {
    
    private func isFileValid(_ fileURL: URL) -> Bool {
        guard fileURL.isExistingFile else {
            return false
        }
        
        //TODO: Check the version file, if it exists
        
        return true
    }
    
    func matchingBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: PinnedVersion, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock?, CarthageError> {
        
        let fileURL = AbstractBinariesCache.fileURL(for: dependency, version: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion)
        
        return URLLock.lockReactive(url: fileURL, timeout: lockTimeout)
            .flatMap(.merge) { (urlLock: URLLock) -> SignalProducer<URLLock?, CarthageError> in
                if self.isFileValid(fileURL) {
                    return SignalProducer(value: urlLock)
                } else {
                    return self.downloadBinary(for: dependency,
                                          pinnedVersion: pinnedVersion,
                                          configuration: configuration,
                                          swiftVersion: swiftVersion,
                                          destinationURL: fileURL,
                                          eventObserver: eventObserver)
                        .then(SignalProducer<URLLock?, CarthageError> { () -> Result<URLLock?, CarthageError> in
                            if urlLock.url.isExistingFile {
                                return .success(urlLock)
                            } else {
                                urlLock.unlock()
                                return .success(nil)
                            }
                        })
                }
            }
    }

    func downloadBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: PinnedVersion, destinationURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?) -> SignalProducer<(), CarthageError> {
        preconditionFailure("Should be implemented by concrete sub class")
    }
}

final class BinaryProjectCache: AbstractBinariesCache {

    let binaryProjectDefinitions: [Dependency: BinaryProject]

    init(binaryProjectDefinitions: [Dependency: BinaryProject]) {
        self.binaryProjectDefinitions = binaryProjectDefinitions
    }
    
    override func downloadBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: PinnedVersion, destinationURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?) -> SignalProducer<(), CarthageError> {
        
        guard let binaryProject = self.binaryProjectDefinitions[dependency], let sourceURL = binaryProject.binaryURL(for: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion) else {
            
            let error: CarthageError
            if let semanticVersion = pinnedVersion.semanticVersion {
                error = CarthageError.requiredVersionNotFound(dependency, VersionSpecifier.exactly(semanticVersion))
            } else {
                error = CarthageError.requiredVersionNotFound(dependency, VersionSpecifier.gitReference(pinnedVersion.commitish))
            }
            
            return SignalProducer<(), CarthageError>(error: error)
        }
        
        let urlRequest = URLRequest(url: sourceURL)
        return URLSession.shared.reactive.download(with: urlRequest)
            .on(started: {
                eventObserver?.send(value: .downloadingBinaries(dependency, pinnedVersion.description))
            })
            .mapError { CarthageError.readFailed(sourceURL, $0 as NSError) }
            .flatMap(.concat) { result -> SignalProducer<URL, CarthageError> in
                let downloadURL = result.0
                return Files.moveFile(from: downloadURL, to: destinationURL)
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }
}

final class GitHubBinariesCache: AbstractBinariesCache {

    let repository: Repository
    let client: Client

    init(repository: Repository, client: Client) {
        self.repository = repository
        self.client = client
    }
    
    override func downloadBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: PinnedVersion, destinationURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?) -> SignalProducer<(), CarthageError> {
        
        return GitHubBinariesCache.downloadMatchingBinary(for: dependency, pinnedVersion: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion, destinationURL: destinationURL, fromRepository: self.repository, client: self.client, eventObserver: eventObserver)
            .flatMapError { [client, repository] error -> SignalProducer<URL, CarthageError> in
                if !client.isAuthenticated {
                    return SignalProducer(error: error)
                }
                return GitHubBinariesCache.downloadMatchingBinary(
                    for: dependency,
                    pinnedVersion: pinnedVersion,
                    configuration: configuration,
                    swiftVersion: swiftVersion,
                    destinationURL: destinationURL,
                    fromRepository: repository,
                    client: Client(server: client.server, isAuthenticated: false),
                    eventObserver: eventObserver
                )
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }

    private static func downloadMatchingBinary(
        for dependency: Dependency,
        pinnedVersion: PinnedVersion,
        configuration: String,
        swiftVersion: PinnedVersion,
        destinationURL: URL,
        fromRepository repository: Repository,
        client: Client,
        eventObserver: Signal<ProjectEvent, NoError>.Observer?
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
                    eventObserver?.send(value: .skippedDownloadingBinaries(dependency, error.message))
                    return .empty

                default:
                    return SignalProducer(error: .gitHubAPIRequestFailed(error))
                }
            }
            .flatMap(.concat) { release -> SignalProducer<URL, CarthageError> in
                return SignalProducer<Release.Asset, CarthageError>(release.assets)
                    .filter { asset in
                        if asset.name.range(of: Constants.Project.binaryAssetPattern) == nil {
                            return false
                        }
                        return Constants.Project.binaryAssetContentTypes.contains(asset.contentType)
                    }
                    .take(first: 1)
                    .flatMap(.concat) { asset -> SignalProducer<URL, CarthageError> in
                        eventObserver?.send(value: .downloadingBinaries(dependency, release.nameWithFallback))
                        return client.download(asset: asset)
                            .mapError(CarthageError.gitHubAPIRequestFailed)
                            .flatMap(.concat) { downloadURL in
                                Files.moveFile(from: downloadURL, to: destinationURL)
                        }
                }
        }
    }
}

class ExternalTaskBinariesCache: AbstractBinariesCache {

    let taskCommand: String

    init(taskCommand: String) {
        self.taskCommand = taskCommand
    }
    
    override func downloadBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, swiftVersion: PinnedVersion, destinationURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?) -> SignalProducer<(), CarthageError> {
        
        let task = self.task(dependencyName: dependency.name, dependencyVersion: pinnedVersion.description, buildConfiguration: configuration, swiftVersion: swiftVersion.description, targetFilePath: destinationURL.path)
        let versionString = pinnedVersion.description

        return task.launch()
            .mapError(CarthageError.taskError)
            .on(started: {
                eventObserver?.send(value: .downloadingBinaries(dependency, versionString))
            })
            .then(SignalProducer<(), CarthageError>.empty)
    }

    private func task(dependencyName: String, dependencyVersion: String, buildConfiguration: String, swiftVersion: String, targetFilePath: String) -> Task {

        var environment = ProcessInfo.processInfo.environment
        environment["CARTHAGE_CACHE_DEPENDENCY_NAME"] = dependencyName
        environment["CARTHAGE_CACHE_DEPENDENCY_VERSION"] = dependencyVersion
        environment["CARTHAGE_CACHE_BUILD_CONFIGURATION"] = buildConfiguration
        environment["CARTHAGE_CACHE_SWIFT_VERSION"] = swiftVersion
        environment["CARTHAGE_CACHE_TARGET_FILE_PATH"] = targetFilePath

        return Task(launchCommand: self.taskCommand, environment: environment)
    }
}
