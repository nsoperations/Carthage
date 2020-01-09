import Foundation
import CarthageKit
import Commandant
import Result
import ReactiveSwift
import ReactiveTask

/// Logs project events put into the sink.
final class ProjectEventLogger {
    private let colorOptions: ColorOptions

    init(colorOptions: ColorOptions) {
        self.colorOptions = colorOptions
    }

    func log(event: ProjectEvent) { // swiftlint:disable:this cyclomatic_complexity
        let formatting = colorOptions.formatting

        switch event {
        case let .cloning(dependency):
            carthage.printOut(formatting.bullets + "Cloning " + formatting.projectName(dependency.name))

        case let .fetching(dependency):
            carthage.printOut(formatting.bullets + "Fetching " + formatting.projectName(dependency.name))

        case let .checkingOut(dependency, revision):
            carthage.printOut(formatting.bullets + "Checking out " + formatting.projectName(dependency.name) + " at " + formatting.quote(revision))

        case let .downloadingBinaryFrameworkDefinition(dependency, url):
            carthage.printOut(formatting.bullets + "Downloading binary-only dependency " + formatting.projectName(dependency.name)
                + " at " + formatting.quote(url.absoluteString))

        case let .downloadingBinaries(dependency, release):
            carthage.printOut(formatting.bullets + "Downloading " + formatting.projectName(dependency.name)
                + " binary at " + formatting.quote(release))

        case let .skippedDownloadingBinaries(dependency, message):
            carthage.printOut(formatting.bullets + "Skipped downloading " + formatting.projectName(dependency.name)
                + " binary: " + message)

        case let .installingBinaries(dependency, release):
            carthage.printOut(formatting.bullets + "Installing " + formatting.projectName(dependency.name)
                + " binary at " + formatting.quote(release))

        case let .storingBinaries(dependency, release):
            carthage.printOut(formatting.bullets + "Storing " + formatting.projectName(dependency.name)
                + " binary at " + formatting.quote(release))

        case let .skippedInstallingBinaries(dependency, error):
            let errorString: String = error.map { String(describing: $0) } ?? "No matching binary found"
            let output: String = formatting.bullets + "Skipped installing \(formatting.projectName(dependency.name)).framework binary: " + errorString
            carthage.printOut(output)

        case let .skippedBuilding(dependency, message):
            carthage.printOut(formatting.bullets + "Skipped building " + formatting.projectName(dependency.name) + ": " + message)

        case let .skippedBuildingCached(dependency):
            carthage.printOut(formatting.bullets + "Valid cache found for " + formatting.projectName(dependency.name) + ", skipping build")

        case let .rebuildingCached(dependency, versionStatus):
            carthage.printOut(formatting.bullets + "Invalid cache found for " + formatting.projectName(dependency.name)
                + " because \(versionStatus.humanReadableDescription), rebuilding with all downstream dependencies")

        case let .buildingUncached(dependency):
            carthage.printOut(formatting.bullets + "No cache found for " + formatting.projectName(dependency.name)
                + ", building with all downstream dependencies")

        case let .rebuildingBinary(dependency, versionStatus):
            carthage.printOut(formatting.bullets + "Invalid binary found for " + formatting.projectName(dependency.name)
                + " because \(versionStatus.humanReadableDescription), rebuilding with all downstream dependencies")

        case let .waiting(url):
            carthage.printOut(formatting.bullets + "Waiting for lock on " + url.path)
            
        case let .warning(message):
            carthage.printOut(formatting.warning("warning: ") + message)
            
        case .crossReferencingSymbols:
            carthage.printOut(formatting.bullets + "Cross-referencing symbols for pre-built binaries")
        }
    }
}

final class ResolverEventLogger {
    let colorOptions: ColorOptions
    let isVerbose: Bool

    init(colorOptions: ColorOptions, verbose: Bool) {
        self.colorOptions = colorOptions
        self.isVerbose = verbose
    }

    func log(event: ResolverEvent) {
        switch event {
        case .foundVersions(let versions, let dependency, let versionSpecifier):
            if isVerbose {
                carthage.printOut("Versions for dependency '\(dependency)' compatible with versionSpecifier \(versionSpecifier): \(versions)")
            }
        case .foundTransitiveDependencies(let transitiveDependencies, let dependency, let version):
            if isVerbose {
                carthage.printOut("Dependencies for dependency '\(dependency)' with version \(version): \(transitiveDependencies)")
            }
        case .failedRetrievingTransitiveDependencies(let error, let dependency, let version):
            carthage.printOut("Caught error while retrieving dependencies for \(dependency) at version \(version): \(error)")
        case .failedRetrievingVersions(let error, let dependency, _):
            carthage.printOut("Caught error while retrieving versions for \(dependency): \(error)")
        case .rejected(let dependencySet, let error):
            if isVerbose {
                carthage.printOut("Rejected dependency set:\n\(dependencySet)\n\nReason: \(error)\n")
            }
        }
    }
}

extension VersionStatus {
    var humanReadableDescription: String {
        switch self {
        case .matching:
            return ""
        case .binaryHashCalculationFailed:
            return "the binary checksum calculation failed"
        case .binaryHashNotEqual:
            return "the binary checksum did not match"
        case .commitishNotEqual:
            return "the commit hash or tag did not match"
        case .configurationNotEqual:
            return "the build configuration did not match"
        case .platformNotFound:
            return "one of the requested platforms was not found"
        case .sourceHashNotEqual:
            return "the source hash did not match"
        case .dependenciesHashNotEqual:
            return "the resolved dependencies hash did not match"
        case .swiftVersionNotEqual:
            return "the swift version did not match the current toolchain"
        case .versionFileNotFound:
            return "the version file was not found"
        case .symbolsNotMatching:
            return "the linked symbols do not match"
        }
    }
}
