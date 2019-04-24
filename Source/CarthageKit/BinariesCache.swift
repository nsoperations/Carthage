import Foundation
import Result
import Tentacle
import ReactiveSwift

/// Cache for binary builds
protocol BinariesCache {

    func matchingBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, cacheBaseURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock, CarthageError>
    
}

class GitHubBinariesCache: BinariesCache {

    let repository: Repository
    let client: Client

    init(repository: Repository, client: Client) {
        self.repository = repository
        self.client = client
    }

    func matchingBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, cacheBaseURL: URL, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?) -> SignalProducer<URLLock, CarthageError> {
        return GitHubBinariesCache.downloadMatchingBinaries(for: dependency, pinnedVersion: pinnedVersion, cacheBaseURL: cacheBaseURL, fromRepository: self.repository, client: self.client, lockTimeout: lockTimeout, eventObserver: eventObserver)
            .flatMapError { [client, repository] error -> SignalProducer<URLLock, CarthageError> in
                if !client.isAuthenticated {
                    return SignalProducer(error: error)
                }
                return GitHubBinariesCache.downloadMatchingBinaries(
                    for: dependency,
                    pinnedVersion: pinnedVersion,
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
                        let fileURL = GitHubBinariesCache.fileURLToCachedBinary(dependency: dependency, release: release, asset: asset, baseURL: cacheBaseURL)
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

    // Constructs a file URL to where the binary corresponding to the given
    /// arguments should live.
    private static func fileURLToCachedBinary(dependency: Dependency, release: Release, asset: Release.Asset, baseURL: URL) -> URL {
        // ~/Library/Caches/org.carthage.CarthageKit/binaries/ReactiveCocoa/v2.3.1/1234-ReactiveCocoa.framework.zip
        return baseURL.appendingPathComponent("\(dependency.name)/\(release.tag)/\(asset.id)-\(asset.name)", isDirectory: false)
    }
}

