import Foundation
import ReactiveSwift
import ReactiveTask
import Result
import XCDBLD

extension MachOType {
    /// Attempts to parse a Mach-O type from a string returned from `xcodebuild`.
    public static func from(string: String) -> Result<MachOType, CarthageError> {
        return Result(self.init(rawValue: string), failWith: .parseError(description: "unexpected Mach-O type \"\(string)\""))
    }
}

extension Platform {
    /// The relative path at which binaries corresponding to this platform will
    /// be stored.
    public var relativePath: String {
        let subfolderName = rawValue
        return Constants.binariesFolderPath.appendingPathComponent(subfolderName)
    }

    /// The relative URL at which binaries corresponding to this platform will
    /// be stored.
    public var relativeURL: URL? {
        let subfolderName = rawValue
        return URL(string: Constants.binariesFolderPath)?.appendingPathComponent(subfolderName, isDirectory: true)
    }
}

extension ProjectLocator {
    
    private static let projectCache = Atomic([URL: Result<[ProjectLocator], CarthageError>]())
    
    /// Attempts to locate projects and workspaces within the given directory.
    ///
    /// Sends all matches in preferential order.
    public static func locate(in directoryURL: URL) -> SignalProducer<ProjectLocator, CarthageError> {
        let result = projectCache.getValue(directoryURL) { directoryURL -> Result<[ProjectLocator], CarthageError> in
            return Git.gitmodulesEntriesInRepository(directoryURL, revision: nil)
            .map { directoryURL.appendingPathComponent($0.path) }
            .concat(value: directoryURL.appendingPathComponent(Constants.checkoutsPath))
            .collect()
            .flatMap(.merge) { directoriesToSkip -> SignalProducer<URL, CarthageError> in
                return FileManager.default.reactive
                    .enumerator(at: directoryURL.resolvingSymlinksInPath(), includingPropertiesForKeys: [.typeIdentifierKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], catchErrors: true)
                    .map { _, url in url }
                    .filter { url in
                        return !directoriesToSkip.contains { $0.hasSubdirectory(url) }
                }
            }
            .filterMap { url -> ProjectLocator? in
                if let uti = url.typeIdentifier {
                    if UTTypeConformsTo(uti as CFString, "com.apple.dt.document.workspace" as CFString) {
                        return .workspace(url)
                    } else if UTTypeConformsTo(uti as CFString, "com.apple.xcode.project" as CFString) {
                        return .projectFile(url)
                    }
                }
                return nil
            }
            .collect()
            .map { $0.sorted() }
            .first()!
        }
        return SignalProducer(result: result).flatten()
    }

    /// Sends each scheme found in the receiver.
    public func schemes() -> SignalProducer<Scheme, CarthageError> {
        return Xcode.listSchemeNames(project: self)
            .map { (line: String) -> Scheme in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return Scheme(trimmed)
        }
    }
}

extension SDK {
    /// Attempts to parse an SDK name from a string returned from `xcodebuild`.
    public static func from(string: String) -> Result<SDK, CarthageError> {
        return Result(self.init(rawValue: string.lowercased()), failWith: .parseError(description: "unexpected SDK key \"\(string)\""))
    }

    /// Split the given SDKs into simulator ones and device ones.
    internal static func splitSDKs<S: Sequence>(_ sdks: S) -> (simulators: [SDK], devices: [SDK]) where S.Iterator.Element == SDK {
        return (
            simulators: sdks.filter { $0.isSimulator },
            devices: sdks.filter { !$0.isSimulator }
        )
    }
}
