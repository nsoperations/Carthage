import Foundation
import Result
import ReactiveSwift
import Tentacle
import XCDBLD
import ReactiveTask
import SPMUtility

import struct Foundation.URL
import enum XCDBLD.Platform

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
}
