import Foundation
import Result
import ReactiveSwift
import Tentacle
import XCDBLD
import ReactiveTask

final class Dependencies {

    /// Returns the string representing a relative path from a dependency back to the root
    static func relativeLinkDestination(for dependency: Dependency, subdirectory: String) -> String {
        let dependencySubdirectoryPath = (dependency.relativePath as NSString).appendingPathComponent(subdirectory)
        let componentsForGettingTheHellOutOfThisRelativePath = Array(repeating: "..", count: (dependencySubdirectoryPath as NSString).pathComponents.count - 1)

        // Directs a link from, e.g., /Carthage/Checkouts/ReactiveCocoa/Carthage/Build to /Carthage/Build
        let linkDestinationPath = componentsForGettingTheHellOutOfThisRelativePath.reduce(subdirectory) { trailingPath, pathComponent in
            return (pathComponent as NSString).appendingPathComponent(trailingPath)
        }

        return linkDestinationPath
    }

    /// Returns the file URL at which the given project's repository will be
    /// located.
    static func repositoryFileURL(for dependency: Dependency, baseURL: URL) -> URL {
        return baseURL.appendingPathComponent(dependency.name, isDirectory: true)
    }

    static func fetchDependencyNameForRepository(at repositoryFileURL: URL?) -> SignalProducer<String, CarthageError> {
        /*
         List all remotes known for this repository
         and keep only the "fetch" urls by which the current repository
         would be known for the purpose of fetching anyways.

         Example of well-formed output:

         $ git remote -v
         origin   https://github.com/blender/Carthage.git (fetch)
         origin   https://github.com/blender/Carthage.git (push)
         upstream https://github.com/Carthage/Carthage.git (fetch)
         upstream https://github.com/Carthage/Carthage.git (push)

         Example of ill-formed output where upstream does not have a url:

         $ git remote -v
         origin   https://github.com/blender/Carthage.git (fetch)
         origin   https://github.com/blender/Carthage.git (push)
         upstream
         */
        let allRemoteURLs = Git.launchGitTask(["remote", "-v"], repositoryFileURL: repositoryFileURL)
            .flatMap(.concat) { $0.linesProducer }
            .map { $0.components(separatedBy: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && $0.last == "(fetch)" } // Discard ill-formed output as of example
            .map { ($0[0], $0[1]) }
            .collect()

        let currentProjectName = allRemoteURLs
            // Assess the popularity of each remote url
            .map { $0.reduce([String: (popularity: Int, remoteNameAndURL: (name: String, url: String))]()) { remoteURLPopularityMap, remoteNameAndURL in
                let (remoteName, remoteUrl) = remoteNameAndURL
                var remoteURLPopularityMap = remoteURLPopularityMap
                if let existingEntry = remoteURLPopularityMap[remoteName] {
                    remoteURLPopularityMap[remoteName] = (existingEntry.popularity + 1, existingEntry.remoteNameAndURL)
                } else {
                    remoteURLPopularityMap[remoteName] = (0, (remoteName, remoteUrl))
                }
                return remoteURLPopularityMap
                }
            }
            // Pick "origin" if it exists,
            // otherwise sort remotes by popularity
            // or alphabetically in case of a draw
            .map { (remotePopularityMap: [String: (popularity: Int, remoteNameAndURL: (name: String, url: String))]) -> String in
                guard let origin = remotePopularityMap["origin"] else {
                    let urlOfMostPopularRemote = remotePopularityMap.sorted { lhs, rhs in
                        if lhs.value.popularity == rhs.value.popularity {
                            return lhs.key < rhs.key
                        }
                        return lhs.value.popularity > rhs.value.popularity
                        }
                        .first?.value.remoteNameAndURL.url

                    // If the reposiroty is not pushed to any remote
                    // the list of remotes is empty, so call the current project... "_Current"
                    return urlOfMostPopularRemote.flatMap { Dependency.git(GitURL($0)).name } ?? "_Current"
                }

                return Dependency.git(GitURL(origin.remoteNameAndURL.url)).name
        }
        return currentProjectName
    }
}
