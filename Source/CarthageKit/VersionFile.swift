import Foundation
import ReactiveSwift
import ReactiveTask
import Result
import XCDBLD
import CommonCrypto

struct CachedFramework: Codable {
    enum CodingKeys: String, CodingKey {
        case name = "name"
        case hash = "hash"
        case swiftToolchainVersion = "swiftToolchainVersion"
    }

    let name: String
    let hash: String
    let swiftToolchainVersion: String?
    var isSwiftFramework: Bool {
        return swiftToolchainVersion != nil
    }
}

public enum VersionStatus: Equatable {
    case matching
    case versionFileNotFound
    case sourceHashNotEqual
    case dependenciesHashNotEqual
    case configurationNotEqual
    case commitishNotEqual
    case platformNotFound
    case swiftVersionNotEqual
    case binaryHashNotEqual
    case binaryHashCalculationFailed
    case symbolsNotMatching(symbols: Set<String>)
}

func &&(lhs: VersionStatus, rhs: VersionStatus) -> VersionStatus {
    if lhs == .matching {
        return rhs
    } else {
        return lhs
    }
}

struct VersionFile: Codable {

    static let sourceHashCache = Atomic(Dictionary<URL, String>())

    enum CodingKeys: String, CodingKey {
        case commitish = "commitish"
        case sourceHash = "sourceHash"
        case resolvedDependenciesHash = "resolvedDependenciesHash"
        case configuration = "configuration"
        case macOS = "Mac"
        case iOS = "iOS"
        case watchOS = "watchOS"
        case tvOS = "tvOS"
    }

    let commitish: String
    let sourceHash: String?
    let resolvedDependenciesHash: String?
    let configuration: String

    let macOS: [CachedFramework]?
    let iOS: [CachedFramework]?
    let watchOS: [CachedFramework]?
    let tvOS: [CachedFramework]?

    /// The extension representing a serialized VersionFile.
    static let pathExtension = "version"

    subscript(_ platform: Platform) -> [CachedFramework]? {
        switch platform {
        case .macOS:
            return macOS

        case .iOS:
            return iOS

        case .watchOS:
            return watchOS

        case .tvOS:
            return tvOS
        }
    }

    init(
        commitish: String,
        sourceHash: String?,
        resolvedDependenciesHash: String?,
        configuration: String,
        macOS: [CachedFramework]?,
        iOS: [CachedFramework]?,
        watchOS: [CachedFramework]?,
        tvOS: [CachedFramework]?
        ) {
        self.commitish = commitish
        self.sourceHash = sourceHash
        self.resolvedDependenciesHash = resolvedDependenciesHash
        self.configuration = configuration
        self.macOS = macOS
        self.iOS = iOS
        self.watchOS = watchOS
        self.tvOS = tvOS
    }

    init?(url: URL) {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let jsonData = try? Data(contentsOf: url) else
        {
            return nil
        }
        try? self.init(jsonData: jsonData)
    }

    init(jsonData: Data) throws {
        self = try JSONDecoder().decode(VersionFile.self, from: jsonData)
    }
    
    private func cachedFrameworkURLs(for platforms: Set<Platform>, in directoryURL: URL) -> [(Platform, URL)] {
        return platforms.reduce(into: [(Platform, URL)]()) { frameworks, platform in
            for cachedFramework in (self[platform] ?? []) {
                let url = directoryURL.appendingPathComponent(platform.relativePath).appendingPathComponent("\(cachedFramework.name).framework")
                frameworks.append((platform, url))
            }
        }
    }

    func frameworkURL(
        for cachedFramework: CachedFramework,
        platform: Platform,
        binariesDirectoryURL: URL
        ) -> URL {
        return binariesDirectoryURL
            .appendingPathComponent(platform.rawValue, isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("\(cachedFramework.name).framework", isDirectory: true)
    }

    func frameworkBinaryURL(
        for cachedFramework: CachedFramework,
        platform: Platform,
        binariesDirectoryURL: URL
        ) -> URL {
        return frameworkURL(
            for: cachedFramework,
            platform: platform,
            binariesDirectoryURL: binariesDirectoryURL
            )
            .appendingPathComponent("\(cachedFramework.name)", isDirectory: false)
    }

    func containsAll(platforms: Set<Platform>) -> Bool {
        let platformsToCheck = platforms.isEmpty ? Set<Platform>(Platform.supportedPlatforms) : platforms
        for platform in platformsToCheck {
            if self[platform] == nil {
                return false
            }
        }
        return true
    }

    /// Sends the hashes of the provided cached framework's binaries in the
    /// order that they were provided in.
    func hashes(
        for cachedFrameworks: [CachedFramework],
        platform: Platform,
        binariesDirectoryURL: URL
        ) -> SignalProducer<String?, CarthageError> {
        return SignalProducer<CachedFramework, CarthageError>(cachedFrameworks)
            .flatMap(.concat) { cachedFramework -> SignalProducer<String?, CarthageError> in
                let frameworkBinaryURL: URL = self.frameworkBinaryURL(
                    for: cachedFramework,
                    platform: platform,
                    binariesDirectoryURL: binariesDirectoryURL
                )

                return VersionFile.hashForFileAtURL(frameworkBinaryURL)
                    .map { hash -> String? in
                        return hash
                    }
                    .flatMapError { _ in
                        return SignalProducer(value: nil)
                }
        }
    }

    /// Sends values indicating whether the provided cached frameworks match the
    /// given local Swift version, in the order of the provided cached
    /// frameworks.
    ///
    /// Non-Swift frameworks are considered as matching the local Swift version,
    /// as they will be compatible with it by definition.
    func swiftVersionMatches(
        for cachedFrameworks: [CachedFramework],
        platform: Platform,
        binariesDirectoryURL: URL,
        localSwiftVersion: PinnedVersion
        ) -> SignalProducer<Bool, CarthageError> {
        return SignalProducer<CachedFramework, CarthageError>(cachedFrameworks)
            .flatMap(.concat) { cachedFramework -> SignalProducer<Bool, CarthageError> in
                let frameworkURL = self.frameworkURL(
                    for: cachedFramework,
                    platform: platform,
                    binariesDirectoryURL: binariesDirectoryURL
                )

                if !Frameworks.isSwiftFramework(frameworkURL) {
                    return SignalProducer(value: true)
                } else {
                    return Frameworks.frameworkSwiftVersion(frameworkURL)
                        .flatMapError { _ in Frameworks.dSYMSwiftVersion(frameworkURL.appendingPathExtension("dSYM")) }
                        .map { swiftVersion -> Bool in
                            return swiftVersion == localSwiftVersion || Frameworks.isModuleStableAPI(localSwiftVersion.semanticVersion, swiftVersion.semanticVersion, frameworkURL)
                        }
                        .flatMapError { _ in SignalProducer<Bool, CarthageError>(value: false) }
                }
        }
    }

    func satisfies(
        platforms: Set<Platform>,
        commitish: String,
        sourceHash: String?,
        configuration: String,
        resolvedDependenciesHash: String?,
        binariesDirectoryURL: URL,
        localSwiftVersion: PinnedVersion
        ) -> SignalProducer<VersionStatus, CarthageError> {
        let platformsToCheck = platforms.isEmpty ? Set<Platform>(Platform.supportedPlatforms) : platforms
        return SignalProducer<Platform, CarthageError>(platformsToCheck)
            .flatMap(.merge) { platform -> SignalProducer<VersionStatus, CarthageError> in
                return self.satisfies(
                    platform: platform,
                    commitish: commitish,
                    sourceHash: sourceHash,
                    configuration: configuration,
                    resolvedDependenciesHash: resolvedDependenciesHash,
                    binariesDirectoryURL: binariesDirectoryURL,
                    localSwiftVersion: localSwiftVersion
                )
            }
            .reduce(VersionStatus.matching) { $0 && $1 }
    }

    func satisfies(
        platform: Platform,
        commitish: String,
        sourceHash: String?,
        configuration: String,
        resolvedDependenciesHash: String?,
        binariesDirectoryURL: URL,
        localSwiftVersion: PinnedVersion
        ) -> SignalProducer<VersionStatus, CarthageError> {
        guard let cachedFrameworks = self[platform] else {
            return SignalProducer(value: .platformNotFound)
        }

        let hashes = self.hashes(
            for: cachedFrameworks,
            platform: platform,
            binariesDirectoryURL: binariesDirectoryURL
            )
            .collect()

        let swiftVersionMatches = self
            .swiftVersionMatches(
                for: cachedFrameworks, platform: platform,
                binariesDirectoryURL: binariesDirectoryURL, localSwiftVersion: localSwiftVersion
            )
            .collect()

        return SignalProducer.zip(hashes, swiftVersionMatches)
            .flatMap(.concat) { hashes, swiftVersionMatches -> SignalProducer<VersionStatus, CarthageError> in
                return self.satisfies(
                    platform: platform,
                    commitish: commitish,
                    sourceHash: sourceHash,
                    configuration: configuration,
                    resolvedDependenciesHash: resolvedDependenciesHash,
                    hashes: hashes,
                    swiftVersionMatches: swiftVersionMatches
                )
        }
    }

    func satisfies(
        platform: Platform,
        commitish: String,
        sourceHash: String?,
        configuration: String,
        resolvedDependenciesHash: String?,
        hashes: [String?],
        swiftVersionMatches: [Bool]
        ) -> SignalProducer<VersionStatus, CarthageError> {
        
        if let definedSourceHash = self.sourceHash, let suppliedSourceHash = sourceHash, definedSourceHash != suppliedSourceHash {
            return SignalProducer(value: .sourceHashNotEqual)
        }
        
        if let suppliedDependenciesHash = resolvedDependenciesHash, suppliedDependenciesHash != self.resolvedDependenciesHash {
            return SignalProducer(value: .dependenciesHashNotEqual)
        }
        
        guard let cachedFrameworks = self[platform] else {
            return SignalProducer(value: .platformNotFound)
        }

        guard commitish == self.commitish else {
            return SignalProducer(value: .commitishNotEqual)
        }
        
        guard configuration == self.configuration else {
            return SignalProducer(value: .configurationNotEqual)
        }

        return SignalProducer
            .zip(
                SignalProducer(hashes),
                SignalProducer(cachedFrameworks),
                SignalProducer(swiftVersionMatches)
            )
            .map { hash, cachedFramework, swiftVersionMatches -> VersionStatus in
                if let hash = hash {
                    if !swiftVersionMatches {
                        return .swiftVersionNotEqual
                    } else if hash != cachedFramework.hash {
                        return .binaryHashNotEqual
                    }
                    return .matching
                } else {
                    return .binaryHashCalculationFailed
                }
            }
            .reduce(VersionStatus.matching) { $0 && $1 }
    }

    func write(to url: URL) -> Result<(), CarthageError> {
        return Result(at: url, attempt: {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted

            let jsonData = try encoder.encode(self)
            try FileManager
                .default
                .createDirectory(
                    at: $0.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
            )
            try jsonData.write(to: $0, options: .atomic)
        })
    }
}

extension VersionFile {

    /// Creates a version file for the current project in the
    /// Carthage/Build directory which associates its commitish with
    /// the hashes (e.g. SHA256) of the built frameworks for each platform
    /// in order to allow those frameworks to be skipped in future builds.
    ///
    /// Derives the current project name from `git remote get-url origin`
    ///
    /// Returns a signal that succeeds once the file has been created.
    static func createVersionFileForCurrentProject(
        projectName: String?,
        commitish: String?,
        platforms: Set<Platform>,
        configuration: String,
        resolvedDependencySet: Set<PinnedDependency>?,
        buildProducts: [URL],
        rootDirectoryURL: URL
        ) -> SignalProducer<(), CarthageError> {

        let currentProjectName: SignalProducer<String, CarthageError>
        let currentGitTagOrCommitish: SignalProducer<String, CarthageError>
        
        if let customCommitish = commitish {
            currentGitTagOrCommitish = SignalProducer<String, CarthageError>(value: customCommitish)
        } else {
            currentGitTagOrCommitish = Git.launchGitTask(["rev-parse", "HEAD"], repositoryFileURL: rootDirectoryURL)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap(.merge) { headCommitish in
                    Git.launchGitTask(["describe", "--tags", "--exact-match", headCommitish])
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .flatMapError { _  in SignalProducer(value: headCommitish) }
            }
        }
        
        if let customProjectName = projectName {
            currentProjectName = SignalProducer<String, CarthageError>(value: customProjectName)
        } else {
            currentProjectName = Dependencies.fetchDependencyNameForRepository(at: rootDirectoryURL)
        }

        return SignalProducer.zip(currentProjectName, currentGitTagOrCommitish)
            .flatMap(.merge) { currentProjectNameString, version in
                createVersionFileForCommitish(
                    version,
                    dependencyName: currentProjectNameString,
                    platforms: platforms,
                    configuration: configuration,
                    resolvedDependencySet: resolvedDependencySet,
                    buildProducts: buildProducts,
                    rootDirectoryURL: rootDirectoryURL
                )
        }
    }

    /// Creates a version file for the current dependency in the
    /// Carthage/Build directory which associates its commitish with
    /// the hashes (e.g. SHA256) of the built frameworks for each platform
    /// in order to allow those frameworks to be skipped in future builds.
    ///
    /// Returns a signal that succeeds once the file has been created.
    static func createVersionFile(
        for dependency: Dependency,
        version: PinnedVersion,
        platforms: Set<Platform>,
        configuration: String,
        resolvedDependencySet: Set<PinnedDependency>?,
        buildProducts: [URL],
        rootDirectoryURL: URL
        ) -> SignalProducer<(), CarthageError> {
        return createVersionFileForCommitish(
            version.commitish,
            dependencyName: dependency.name,
            platforms: platforms,
            configuration: configuration,
            resolvedDependencySet: resolvedDependencySet,
            buildProducts: buildProducts,
            rootDirectoryURL: rootDirectoryURL
        )
    }

    /// Creates a version file for the dependency in the given root directory with:
    /// - The given commitish
    /// - The provided project name
    /// - The location of the built frameworks products for all platforms
    ///
    /// Returns a signal that succeeds once the file has been created.
    static func createVersionFileForCommitish(
        _ commitish: String,
        dependencyName: String,
        platforms: Set<Platform> = Set(Platform.supportedPlatforms),
        configuration: String,
        resolvedDependencySet: Set<PinnedDependency>?,
        buildProducts: [URL],
        rootDirectoryURL: URL
        ) -> SignalProducer<(), CarthageError> {
        var platformCaches: [String: [CachedFramework]] = [:]

        let platformsToCache = platforms.isEmpty ? Set(Platform.supportedPlatforms) : platforms
        for platform in platformsToCache {
            platformCaches[platform.rawValue] = []
        }

        struct FrameworkDetail {
            let platformName: String
            let frameworkName: String
            let frameworkSwiftVersion: String?
        }
        
        let resolvedDependenciesHash = resolvedDependencySet.map { Frameworks.hashForResolvedDependencySet($0) }

        if !buildProducts.isEmpty {
            return SignalProducer<URL, CarthageError>(buildProducts)
                .flatMap(.merge) { url -> SignalProducer<(String, FrameworkDetail), CarthageError> in
                    let frameworkName = url.deletingPathExtension().lastPathComponent
                    let platformName = url.deletingLastPathComponent().lastPathComponent
                    return Frameworks.frameworkSwiftVersionIfIsSwiftFramework(url)
                        .mapError { swiftVersionError -> CarthageError in .incompatibleFrameworkSwiftVersion(swiftVersionError.description) }
                        .flatMap(.merge) { frameworkSwiftVersion -> SignalProducer<(String, FrameworkDetail), CarthageError> in
                            let frameworkDetail: FrameworkDetail = .init(platformName: platformName,
                                                                         frameworkName: frameworkName,
                                                                         frameworkSwiftVersion: frameworkSwiftVersion?.description)
                            let details = SignalProducer<FrameworkDetail, CarthageError>(value: frameworkDetail)
                            let binaryURL = url.appendingPathComponent(frameworkName, isDirectory: false)
                            return SignalProducer.zip(hashForFileAtURL(binaryURL), details)
                    }
                }
                .reduce(into: platformCaches) { (platformCaches: inout [String: [CachedFramework]], values: (String, FrameworkDetail)) in
                    let hash = values.0
                    let platformName = values.1.platformName
                    let frameworkName = values.1.frameworkName
                    let frameworkSwiftVersion = values.1.frameworkSwiftVersion

                    let cachedFramework = CachedFramework(name: frameworkName, hash: hash, swiftToolchainVersion: frameworkSwiftVersion)
                    if var frameworks = platformCaches[platformName] {
                        frameworks.append(cachedFramework)
                        platformCaches[platformName] = frameworks
                    }
                }
                .flatMap(.merge) { platformCaches -> SignalProducer<(), CarthageError> in
                    createVersionFile(
                        commitish,
                        dependencyName: dependencyName,
                        configuration: configuration,
                        resolvedDependenciesHash: resolvedDependenciesHash,
                        rootDirectoryURL: rootDirectoryURL,
                        platformCaches: platformCaches
                    )
            }
        } else {
            // Write out an empty version file for dependencies with no built frameworks, so cache builds can differentiate between
            // no cache and a dependency that has no frameworks
            return createVersionFile(
                commitish,
                dependencyName: dependencyName,
                configuration: configuration,
                resolvedDependenciesHash: resolvedDependenciesHash,
                rootDirectoryURL: rootDirectoryURL,
                platformCaches: platformCaches
            )
        }
    }

    static func versionFileRelativePath(dependencyName: String) -> String {
        return Constants.binariesFolderPath.appendingPathComponent(".\(dependencyName).\(VersionFile.pathExtension)")
    }

    /// Returns the URL where the version file for the specified dependency should reside.
    static func versionFileURL(dependencyName: String, rootDirectoryURL: URL) -> URL {
        let rootBinariesURL = rootDirectoryURL
            .appendingPathComponent(Constants.binariesFolderPath, isDirectory: true)
            .resolvingSymlinksInPath()
        let versionFileURL = rootBinariesURL
            .appendingPathComponent(".\(dependencyName).\(VersionFile.pathExtension)")
        return versionFileURL
    }

    /// Determines whether a dependency can be skipped because it is
    /// already cached.
    ///
    /// If a set of platforms is not provided, all platforms are checked.
    ///
    /// Returns an optional bool which is nil if no version file exists,
    /// otherwise true if the version file matches and the build can be
    /// skipped or false if there is a mismatch of some kind.
    static func versionFileMatches(
        _ dependency: Dependency,
        version: PinnedVersion,
        platforms: Set<Platform>,
        configuration: String,
        resolvedDependencySet: Set<PinnedDependency>?,
        rootDirectoryURL: URL,
        toolchain: String?,
        checkSourceHash: Bool,
        externallyDefinedSymbols: [PlatformFramework: Set<String>]? = nil
        ) -> SignalProducer<VersionStatus, CarthageError> {
        let versionFileURL = self.versionFileURL(dependencyName: dependency.name, rootDirectoryURL: rootDirectoryURL)
        guard let versionFile = VersionFile(url: versionFileURL) else {
            return SignalProducer(value: .versionFileNotFound)
        }
        let rootBinariesURL = versionFileURL.deletingLastPathComponent()
        let commitish = version.commitish
        let resolvedDependenciesHash = resolvedDependencySet.map { Frameworks.hashForResolvedDependencySet($0) }

        return SwiftToolchain.swiftVersion(usingToolchain: toolchain)
            .mapError { error in CarthageError.internalError(description: error.description) }
            .combineLatest(with: checkSourceHash ? self.sourceHash(dependencyName: dependency.name, commitish: commitish, rootDirectoryURL: rootDirectoryURL) : SignalProducer<String?, CarthageError>(value: nil))
            .flatMap(.concat) { localSwiftVersion, sourceHash -> SignalProducer<VersionStatus, CarthageError> in
                return versionFile.satisfies(platforms: platforms,
                                             commitish: commitish,
                                             sourceHash: sourceHash,
                                             configuration: configuration,
                                             resolvedDependenciesHash: resolvedDependenciesHash,
                                             binariesDirectoryURL: rootBinariesURL,
                                             localSwiftVersion: localSwiftVersion)
            }
            .flatMap(.concat) { status -> SignalProducer<VersionStatus, CarthageError> in
                if let externalSymbols = externallyDefinedSymbols, status == .matching {
                    for (platform, frameworkURL) in versionFile.cachedFrameworkURLs(for: platforms, in: rootDirectoryURL) {
                        switch Frameworks.undefinedSymbols(frameworkURL: frameworkURL) {
                        case let .success(undefinedSymbols):
                            for (name, symbols) in undefinedSymbols {
                                if let eSymbols = externalSymbols[PlatformFramework(name: name, platform: platform)] {
                                    let diffSet = symbols.subtracting(eSymbols)
                                    if !diffSet.isEmpty {
                                        #if DEBUG
                                        print("Found the following undefined symbols:")
                                        print(diffSet.joined(separator: "\n"))
                                        #endif
                                        return SignalProducer(value: .symbolsNotMatching(symbols: diffSet))
                                    }
                                }
                            }
                        case let .failure(error):
                            return SignalProducer(error: error)
                        }
                    }
                }
                return SignalProducer(value: status)
            }
    }

    // MARK: - Private
    
    private static func createVersionFile(
        _ commitish: String,
        dependencyName: String,
        configuration: String,
        resolvedDependenciesHash: String?,
        rootDirectoryURL: URL,
        platformCaches: [String: [CachedFramework]]
        ) -> SignalProducer<(), CarthageError> {

        return self.sourceHash(dependencyName: dependencyName, commitish: commitish, rootDirectoryURL: rootDirectoryURL)
            .flatMap(.merge) { sourceHash -> SignalProducer<(), CarthageError> in
                return SignalProducer<(), CarthageError> { () -> Result<(), CarthageError> in
                    let versionFileURL = self.versionFileURL(dependencyName: dependencyName, rootDirectoryURL: rootDirectoryURL)
                    let versionFile = VersionFile(
                        commitish: commitish,
                        sourceHash: sourceHash,
                        resolvedDependenciesHash: resolvedDependenciesHash,
                        configuration: configuration,
                        macOS: platformCaches[Platform.macOS.rawValue],
                        iOS: platformCaches[Platform.iOS.rawValue],
                        watchOS: platformCaches[Platform.watchOS.rawValue],
                        tvOS: platformCaches[Platform.tvOS.rawValue])

                    return versionFile.write(to: versionFileURL)
                }
        }
    }

    private static func hashForFileAtURL(_ frameworkFileURL: URL) -> SignalProducer<String, CarthageError> {
        return SignalProducer<String, CarthageError> { () -> Result<String, CarthageError> in
            return SHA256Digest.digestForFileAtURL(frameworkFileURL).map{ $0.hexString }
        }
    }

    private static var defaultGitIgnore: GitIgnore = {
        let defaultIgnoreList =
        """
        # Finder droppings
        .DS_Store

        # User-specific Xcode files
        **/xcuserdata/**
        **/xcdebugger/**
        *.xccheckout
        *.xcscmblueprint

        # Do not track schemes, to avoid cache invalidation with scheme auto-generation on
        *.xcscheme
        IDEWorkspaceChecks.plist
        WorkspaceSettings.xcsettings

        # Temporary files
        *.swp
        *.orig
        *.ori
        *.bak
        *.tmp

        # AppCode
        .idea

        # Hidden files and directories
        .*

        # Code coverage
        *.gcn?
        *.gcda

        # Carthage
        Carthage

        # CocoaPods
        Pods
        """
        return GitIgnore(string: defaultIgnoreList)
    }()

    private static func sourceHash(dependencyName: String, commitish: String, rootDirectoryURL: URL) -> SignalProducer<String?, CarthageError> {
        return SignalProducer<String?, CarthageError> { () -> Result<String?, CarthageError> in
            let dependencyDir = rootDirectoryURL.appendingPathComponent(Dependency.relativePath(dependencyName: dependencyName))

            guard dependencyDir.isExistingDirectory else {
                // No hash can be calculated if there is no source dir, this is ok, binaries don't contain sources.
                return .success(nil)
            }
            
            if let cachedHexString = VersionFile.sourceHashCache[dependencyDir] {
                return .success(cachedHexString)
            }
                    
            let result = SHA256Digest.digestForDirectoryAtURL(dependencyDir, version: commitish, parentGitIgnore: defaultGitIgnore).map{ $0.hexString as String? }
            guard let hexString = result.value else {
                return result
            }

            // Store in cache
            VersionFile.sourceHashCache[dependencyDir] = hexString

            return .success(hexString)
        }
    }
}
