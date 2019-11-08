// swiftlint:disable file_length

import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD

typealias ProjectScheme = (project: ProjectLocator, scheme: Scheme)

public final class Xcode {
    
    private static let buildSettingsCache = Cache<BuildArguments, Result<[BuildSettings], CarthageError>>()
    private static let destinationsCache = Cache<SDK, Result<String?, CarthageError>>()

    /// Attempts to build the dependency, then places its build product into the
    /// root directory given.
    ///
    /// Returns producers in the same format as buildInDirectory().
    static func build(
        dependency: Dependency,
        version: PinnedVersion,
        rootDirectoryURL: URL,
        withOptions options: BuildOptions,
        lockTimeout: Int? = nil,
        builtProductsHandler: (([URL]) -> CarthageResult<()>)? = nil
        ) -> CarthageResult<()> {
        let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
        let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()
        
        return buildInDirectory(dependencyURL,
                                withOptions: options,
                                dependency: (dependency, version),
                                rootDirectoryURL: rootDirectoryURL,
                                lockTimeout: lockTimeout,
                                builtProductsHandler: builtProductsHandler
            ).mapError { error in
                switch (dependency, error) {
                case let (_, .noSharedFrameworkSchemes(_, platforms)):
                    return .noSharedFrameworkSchemes(dependency, platforms)

                case let (.gitHub(repo), .noSharedSchemes(project, _)):
                    return .noSharedSchemes(project, repo)

                default:
                    return error
                }
        }
    }

    /// Builds the any shared framework schemes found within the given directory.
    ///
    /// Returns a signal of all standard output from `xcodebuild`, and each scheme being built.
    static func buildInDirectory( // swiftlint:disable:this static function_body_length
        _ directoryURL: URL,
        withOptions options: BuildOptions,
        dependency: (dependency: Dependency, version: PinnedVersion)? = nil,
        rootDirectoryURL: URL,
        lockTimeout: Int? = nil,
        customProjectName: String? = nil,
        customCommitish: String? = nil,
        builtProductsHandler: (([URL]) -> CarthageResult<()>)? = nil
        ) -> CarthageResult<()> {
        precondition(directoryURL.isFileURL)
        
        return CarthageResult.catching {
            try URLLock.locked(url: URL(fileURLWithPath: options.derivedDataPath ?? Constants.Dependency.derivedDataURL.path)) { url in
                let schemeMatcher = SchemeCartfile.from(directoryURL: directoryURL).value?.matcher
                let projectSchemes: [ProjectScheme] = try buildableSchemesInDirectory(directoryURL, withConfiguration: options.configuration, forPlatforms: options.platforms, schemeMatcher: schemeMatcher).get()
                
                for projectScheme in projectSchemes {
                
                    let builtProductUrls = try buildScheme(
                        projectScheme.scheme,
                        withOptions: options,
                        inProject: projectScheme.project,
                        rootDirectoryURL: rootDirectoryURL,
                        workingDirectoryURL: directoryURL
                    )
                    .mapError { error -> CarthageError in
                        if case let .taskError(taskError) = error {
                            return .buildFailed(taskError, log: nil)
                        } else {
                            return error
                        }
                    }
                    .get()
                        
                    if let dependency = dependency {
                        try VersionFile.createVersionFile(
                            for: dependency.dependency,
                            version: dependency.version,
                            platforms: options.platforms,
                            configuration: options.configuration,
                            buildProducts: builtProductUrls,
                            rootDirectoryURL: rootDirectoryURL
                            )
                            .wait()
                            .get()
                        
                    } else {
                        // Is only possible if the current project is a git repository, because the version file is tied to commit hash
                        if rootDirectoryURL.isGitDirectory {
                            try VersionFile.createVersionFileForCurrentProject(
                                projectName: customProjectName,
                                commitish: customCommitish,
                                platforms: options.platforms,
                                configuration: options.configuration,
                                buildProducts: builtProductUrls,
                                rootDirectoryURL: rootDirectoryURL
                                )
                                .wait()
                                .get()
                        }
                    }
                    try builtProductsHandler?(builtProductUrls).get()
                }
            }
        }
    }
    
    private static func projectSchemes(directoryURL: URL) -> Result<[ProjectLocator:[Scheme]], CarthageError> {
        return ProjectLocator
            .locate(in: directoryURL)
            .flatMap({ projects -> CarthageResult<[ProjectLocator:[Scheme]]> in
                return CarthageResult.catching { () -> [ProjectLocator:[Scheme]] in
                    try projects.reduce(into: [ProjectLocator:[Scheme]]()) { dict, project in
                        dict[project, default: [Scheme]()].append(contentsOf: try project.schemes().get())
                    }
                }
            })
    }

    /// Finds schemes of projects or workspaces, which Carthage should build, found
    /// within the given directory.
    static func buildableSchemesInDirectory( // swiftlint:disable:this static function_body_length
        _ directoryURL: URL,
        withConfiguration configuration: String,
        forPlatforms platforms: Set<Platform> = [],
        schemeMatcher: SchemeMatcher?
        ) -> CarthageResult<[ProjectScheme]> {
        precondition(directoryURL.isFileURL)
        
        return CarthageResult.catching { () -> [ProjectScheme] in
        
            let projectSchemes: [ProjectLocator: [Scheme]] = try self.projectSchemes(directoryURL: directoryURL).get()
            
            if projectSchemes.isEmpty {
                // No schemes and no projects: just return
                return []
            }
            
            var ret = [ProjectScheme]()
            
            //TODO: construct workspace lookup dictionary, by reading the contents of the workspace
            let workspaceLookupDict = [ProjectLocator: ProjectLocator]()
            
            for (project, schemes) in projectSchemes where !project.isWorkspace {
                for scheme in schemes {
                    let buildArguments = BuildArguments(project: project, scheme: scheme, configuration: configuration)
                    if shouldBuildScheme(buildArguments, forPlatforms: platforms, schemeMatcher: schemeMatcher).value == true {
                        if let workspace = workspaceLookupDict[project] {
                            ret.append((workspace, scheme))
                        } else {
                            ret.append((project, scheme))
                        }
                    }
                }
            }
            return ret
        }
    }

    /// Invokes `xcodebuild` to retrieve build settings for the given build
    /// arguments.
    ///
    /// Upon .success, sends one BuildSettings value for each target included in
    /// the referenced scheme.
    static func loadBuildSettings(with arguments: BuildArguments, for action: BuildArguments.Action? = nil) -> CarthageResult<[BuildSettings]> {
        // xcodebuild (in Xcode 8.0) has a bug where xcodebuild -showBuildSettings
        // can hang indefinitely on projects that contain core data models.
        // rdar://27052195
        // Including the action "clean" works around this issue, which is further
        // discussed here: https://forums.developer.apple.com/thread/50372
        //
        // "archive" also works around the issue above so use it to determine if
        // it is configured for the archive action.
        
        return buildSettingsCache.getValue(key: arguments) { arguments in
            let task = xcodebuildTask(["archive", "-showBuildSettings", "-skipUnavailableActions"], arguments)
            return task.launch()
                .ignoreTaskData()
                .mapError(CarthageError.taskError)
                // xcodebuild has a bug where xcodebuild -showBuildSettings
                // can sometimes hang indefinitely on projects that don't
                // share any schemes, so automatically bail out if it looks
                // like that's happening.
                .timeout(after: 60, raising: .xcodebuildTimeout(arguments.project), on: QueueScheduler(qos: .default))
                .map { data in
                    return String(data: data, encoding: .utf8)!
                }
                .only()
                .map {
                    return BuildSettings.parseBuildSettings(string: $0, arguments: arguments, action: action)
                }
        }
    }

    // MARK: - Internal

    /// Strips a framework from unexpected architectures and potentially debug symbols,
    /// optionally codesigning the result.
    /// This method is used in a test case, but it should be private
    static func stripFramework(
        _ frameworkURL: URL,
        keepingArchitectures: [String],
        strippingDebugSymbols: Bool,
        codesigningIdentity: String? = nil
        ) -> Result<(), CarthageError> {

        return stripBinary(frameworkURL, keepingArchitectures: keepingArchitectures)
            .flatMap {
                strippingDebugSymbols ? stripDebugSymbols(frameworkURL) : .success(())
            }
            .flatMap {
                stripHeadersDirectory(frameworkURL)
            }
            .flatMap {
                stripPrivateHeadersDirectory(frameworkURL)
            }
            .flatMap {
                stripModulesDirectory(frameworkURL)
            }
            .flatMap {
                codesigningIdentity.map({ codesign(frameworkURL, $0) }) ?? .success(())
            }
    }

    /// Strips a universal file from unexpected architectures.
    static func stripBinary(_ binaryURL: URL, keepingArchitectures: [String]) -> CarthageResult<()> {
        return Frameworks.architecturesInPackage(binaryURL)
            .filter { !keepingArchitectures.contains($0) }
            .flatMap(.concat) { stripArchitecture(binaryURL, $0) }
            .wait()
    }

    // MARK: - Private

    /// Creates a task description for executing `xcodebuild` with the given
    /// arguments.
    private static func xcodebuildTask(_ tasks: [String], _ buildArguments: BuildArguments) -> Task {
        return Task("/usr/bin/xcrun", arguments: buildArguments.arguments + tasks)
    }

    /// Creates a task description for executing `xcodebuild` with the given
    /// arguments.
    private static func xcodebuildTask(_ task: String, _ buildArguments: BuildArguments) -> Task {
        return xcodebuildTask([task], buildArguments)
    }

    /// Finds the built product for the given settings, then copies it (preserving
    /// its name) into the given folder. The folder will be created if it does not
    /// already exist.
    ///
    /// If this built product has any *.bcsymbolmap files they will also be copied.
    ///
    /// Returns a signal that will send the URL after copying upon .success.
    private static func copyBuildProductIntoDirectory(directoryURL: URL, settings: BuildSettings) -> CarthageResult<URL> {
        return CarthageResult.catching {
            let target = try settings.wrapperName.map(directoryURL.appendingPathComponent).get()
            let source = try settings.wrapperURL.get()
            let url = try Files.copyFile(from: source.resolvingSymlinksInPath(), to: target).getOnly()
            _ = try copyBCSymbolMapsForBuildProductIntoDirectory(directoryURL: directoryURL, settings: settings).get()
            return url
        }
    }

    /// Finds any *.bcsymbolmap files for the built product and copies them into
    /// the given folder. Does nothing if bitcode is disabled.
    ///
    /// Returns a signal that will send the URL after copying for each file.
    private static func copyBCSymbolMapsForBuildProductIntoDirectory(directoryURL: URL, settings: BuildSettings) -> CarthageResult<[URL]> {
        return CarthageResult.catching {
            if settings.bitcodeEnabled.value == true {
                let wrapperURL = try settings.wrapperURL.get()
                return try Frameworks.BCSymbolMapsForFramework(wrapperURL)
                    .copyFileURLsIntoDirectory(directoryURL)
                    .collect()
                    .getOnly()
            } else {
                return []
            }
        }
    }

    /// Attempts to merge the given executables into one fat binary, written to
    /// the specified URL.
    private static func mergeExecutables(executableURLs: [URL], outputURL: URL) -> CarthageResult<()> {
        precondition(outputURL.isFileURL)
        
        if let nonFileURL = executableURLs.first(where: { !$0.isFileURL }) {
             return .failure(CarthageError.parseError(description: "expected file URL to built executable, got \(nonFileURL)"))
        }
        
        let executablePaths = executableURLs.map { $0.path }
        let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-create" ] + executablePaths + [ "-output", outputURL.path ])

        return lipoTask.launch()
            .mapError(CarthageError.taskError)
            .wait()
    }

    private static func mergeSwiftHeaderFiles(_ simulatorExecutableURL: URL,
                                              _ deviceExecutableURL: URL,
                                              _ executableOutputURL: URL) -> CarthageResult<()> {
        precondition(simulatorExecutableURL.isFileURL)
        precondition(deviceExecutableURL.isFileURL)
        precondition(executableOutputURL.isFileURL)

        let includeTargetConditionals = """
                                    #ifndef TARGET_OS_SIMULATOR
                                    #include <TargetConditionals.h>
                                    #endif\n
                                    """
        let conditionalPrefix = "#if TARGET_OS_SIMULATOR\n"
        let conditionalElse = "\n#else\n"
        let conditionalSuffix = "\n#endif\n"

        let includeTargetConditionalsContents = includeTargetConditionals.data(using: .utf8)!
        let conditionalPrefixContents = conditionalPrefix.data(using: .utf8)!
        let conditionalElseContents = conditionalElse.data(using: .utf8)!
        let conditionalSuffixContents = conditionalSuffix.data(using: .utf8)!

        guard let simulatorHeaderURL = simulatorExecutableURL.deletingLastPathComponent().swiftHeaderURL() else { return .success(()) }
        guard let simulatorHeaderContents = FileManager.default.contents(atPath: simulatorHeaderURL.path) else { return .success(()) }
        guard let deviceHeaderURL = deviceExecutableURL.deletingLastPathComponent().swiftHeaderURL() else { return .success(()) }
        guard let deviceHeaderContents = FileManager.default.contents(atPath: deviceHeaderURL.path) else { return .success(()) }
        guard let outputURL = executableOutputURL.deletingLastPathComponent().swiftHeaderURL() else { return .success(()) }

        var fileContents = Data()

        fileContents.append(includeTargetConditionalsContents)
        fileContents.append(conditionalPrefixContents)
        fileContents.append(simulatorHeaderContents)
        fileContents.append(conditionalElseContents)
        fileContents.append(deviceHeaderContents)
        fileContents.append(conditionalSuffixContents)

        if FileManager.default.createFile(atPath: outputURL.path, contents: fileContents) {
            return .success(())
        } else {
            return .failure(.writeFailed(outputURL, nil))
        }
    }

    /// If the given source URL represents an LLVM module, copies its contents into
    /// the destination module.
    ///
    /// Sends the URL to each file after copying.
    private static func mergeModuleIntoModule(_ sourceModuleDirectoryURL: URL, _ destinationModuleDirectoryURL: URL) -> CarthageResult<[URL]> {
        precondition(sourceModuleDirectoryURL.isFileURL)
        precondition(destinationModuleDirectoryURL.isFileURL)

        return FileManager.default.reactive
            .enumerator(at: sourceModuleDirectoryURL, includingPropertiesForKeys: [], options: [ .skipsSubdirectoryDescendants, .skipsHiddenFiles ], catchErrors: true)
            .attemptMap { _, url -> CarthageResult<URL> in
                let lastComponent = url.lastPathComponent
                let destinationURL = destinationModuleDirectoryURL.appendingPathComponent(lastComponent).resolvingSymlinksInPath()
                return CarthageResult.catching {
                    try FileManager.default.copyItem(at: url, to: destinationURL, avoiding·rdar·32984063: true)
                    return destinationURL
                }
            }
            .collect()
            .only()
    }

    /// Determines whether the given scheme should be built automatically.
    private static func shouldBuildScheme(_ buildArguments: BuildArguments, forPlatforms: Set<Platform>, schemeMatcher: SchemeMatcher?) -> CarthageResult<Bool> {
        precondition(buildArguments.scheme != nil)

        guard schemeMatcher?.matches(scheme: buildArguments.scheme!) ?? true else {
            return .success(false)
        }

        return loadBuildSettings(with: buildArguments)
            .map { settingsArray in
                return settingsArray.contains { (settings) -> Bool in
                    if settings.frameworkType.value == nil {
                        return false
                    }
                    
                    if forPlatforms.isEmpty {
                        return true
                    }
                    
                    let buildSDKs = settings.buildSDKs.value ?? []
                    return buildSDKs.contains {forPlatforms.contains($0.platform) }
                }
            }
    }

    /// Combines the built products corresponding to the given settings, by creating
    /// a fat binary of their executables and merging any Swift modules together,
    /// generating a new built product in the given directory.
    ///
    /// In order for this process to make any sense, the build products should have
    /// been created from the same target, and differ only in the SDK they were
    /// built for.
    ///
    /// Any *.bcsymbolmap files for the built products are also copied.
    ///
    /// Upon .success, sends the URL to the merged product, then completes.
    private static func mergeBuildProducts(
        deviceBuildSettings: BuildSettings,
        simulatorBuildSettings: BuildSettings,
        into destinationFolderURL: URL
        ) -> CarthageResult<URL> {
        
        return CarthageResult.catching { () -> URL in
            let productURL: URL = try copyBuildProductIntoDirectory(directoryURL: destinationFolderURL, settings: deviceBuildSettings).get()
            let executableURLs: [URL] = [try deviceBuildSettings.executableURL.get(), try simulatorBuildSettings.executableURL.get()]
            let outputURL: URL = destinationFolderURL.appendingPathComponent(try deviceBuildSettings.executablePath.get())
            
            // Merge product binaries
            try mergeExecutables(executableURLs: executableURLs.map { $0.resolvingSymlinksInPath() }, outputURL: outputURL.resolvingSymlinksInPath() ).get()
            
            if Frameworks.isSwiftFramework(productURL) {
                // Merge Product Swift Header Files
                let simulatorURL = try simulatorBuildSettings.executableURL.get()
                let deviceURL = try deviceBuildSettings.executableURL.get()
                try mergeSwiftHeaderFiles(simulatorURL.resolvingSymlinksInPath(), deviceURL.resolvingSymlinksInPath(), outputURL.resolvingSymlinksInPath()).get()
            }
            
            if let simulatorModulesPath: String = try simulatorBuildSettings.relativeModulesPath.get(),
                let deviceModulesPath: String = try deviceBuildSettings.relativeModulesPath.get() {
                
                let productsURL: URL = try simulatorBuildSettings.builtProductsDirectoryURL.get()
                let sourceModulesURL: URL = productsURL.appendingPathComponent(simulatorModulesPath)
                let destinationModulesURL: URL = destinationFolderURL.appendingPathComponent(deviceModulesPath)
                _ = try mergeModuleIntoModule(sourceModulesURL, destinationModulesURL).get()
            }
            
            _ = try copyBCSymbolMapsForBuildProductIntoDirectory(directoryURL: destinationFolderURL, settings: simulatorBuildSettings).get()
            
            return productURL
        }
    }

    /// Builds one scheme of the given project, for all supported SDKs.
    private static func buildScheme( // swiftlint:disable:this static function_body_length cyclomatic_complexity
        _ scheme: Scheme,
        withOptions options: BuildOptions,
        inProject project: ProjectLocator,
        rootDirectoryURL: URL,
        workingDirectoryURL: URL
        ) -> CarthageResult<[URL]> {
        precondition(workingDirectoryURL.isFileURL)
        
        return CarthageResult.catching { () -> [URL] in
            
            var builtProductURLs = [URL]()
            
            let sdkFilter: (BuildSettings, SDK) -> Bool = { settings, sdk in
                return (options.platforms.isEmpty || options.platforms.contains(sdk.platform)) &&
                    (settings.bitcodeEnabled.value == true || ![.tvOS, .watchOS].contains(sdk))
            }
            let allSettings: [BuildSettings] = try loadBuildSettings(with: BuildArguments(project: project, scheme: scheme)).get()
            let sdksToBuild = allSettings.reduce(into: Set<SDK>()) { set, settings in
                if let targetSDKs = settings.buildSDKs.value {
                    for sdk in targetSDKs where sdkFilter(settings, sdk) {
                        set.insert(sdk)
                    }
                }
            }
            
            switch sdksToBuild.count {
            case 0:
                // Don't do anything, no sdks to build
                break
            case 1:
                // Only device or simulator
                let sdk = sdksToBuild.first!
                let folderURL = rootDirectoryURL.appendingPathComponent(sdk.platform.relativePath, isDirectory: true).resolvingSymlinksInPath()
                
                for builtSettings in try build(project: project, scheme: scheme, sdk: sdk, options: options, in: workingDirectoryURL).get() {
                    let builtProductURL = try copyBuildProductIntoDirectory(directoryURL: builtSettings.productDestinationPath(in: folderURL), settings: builtSettings).get()
                    if Frameworks.UUIDsForFramework(builtProductURL).first() != nil {
                        _ = try createDebugInformation(builtProductURL).get()
                    }
                    builtProductURLs.append(builtProductURL)
                }
            case 2:
                // Both device and simulator
                let (simulatorSDKs, deviceSDKs) = SDK.splitSDKs(sdksToBuild)
                guard let deviceSDK = deviceSDKs.first else {
                    throw CarthageError.internalError(description: "Could not find device SDK in \(sdksToBuild)")
                }
                guard let simulatorSDK = simulatorSDKs.first else {
                    throw CarthageError.internalError(description: "Could not find simulator SDK in \(sdksToBuild)")
                }
                guard simulatorSDK.platform == deviceSDK.platform else {
                    throw CarthageError.internalError(description: "Device and simulator platform do not match for SDKs: \(deviceSDK), \(simulatorSDK)")
                }
                
                let platform = simulatorSDK.platform
                let folderURL = rootDirectoryURL.appendingPathComponent(platform.relativePath, isDirectory: true).resolvingSymlinksInPath()
                
                let deviceTargetSettings: [String: BuildSettings] = try build(project: project, scheme: scheme, sdk: deviceSDK, options: options, in: workingDirectoryURL)
                    .get()
                    .reduce(into: [:]) { dict, settings in
                    dict[settings.target] = settings
                }
                let simulatorTargetSettings: [String: BuildSettings] = try build(project: project, scheme: scheme, sdk: simulatorSDK, options: options, in: workingDirectoryURL)
                    .get()
                    .reduce(into: [:]) { dict, settings in
                    dict[settings.target] = settings
                }
                
                if deviceTargetSettings.keys != simulatorTargetSettings.keys {
                    throw CarthageError.internalError(description: "")
                }
                
                for targetName in deviceTargetSettings.keys {
                    guard let deviceSettings = deviceTargetSettings[targetName], let simulatorSettings = simulatorTargetSettings[targetName] else {
                        fatalError("Expected both deviceSettings and simulatorSettings to be present because the keysets have been checked to be identical")
                    }
                    let builtProductURL = try mergeBuildProducts(
                        deviceBuildSettings: deviceSettings,
                        simulatorBuildSettings: simulatorSettings,
                        into: deviceSettings.productDestinationPath(in: folderURL)
                    ).get()
                    builtProductURLs.append(builtProductURL)
                }
            default:
                throw CarthageError.internalError(description: "SDK count \(sdksToBuild.count) in scheme \(scheme) is not supported")
            }
            
            return builtProductURLs
        }
    }

    /// Fixes problem when more than one xcode target has the same Product name for same Deployment target and configuration by deleting TARGET_BUILD_DIR.
    private static func removeTargetBuildDirectory(for settings: BuildSettings) -> CarthageResult<()> {
        return settings.targetBuildDirectory.flatMap { buildDir in
            return Task("/usr/bin/xcrun", arguments: ["rm", "-rf", buildDir])
                .launch()
                .mapError(CarthageError.taskError)
                .wait()
        }
    }
    
    // If SDK is the iOS simulator, then also find and set a valid destination.
    // This fixes problems when the project deployment version is lower than
    // the target's one and includes simulators unsupported by the target.
    //
    // Example: Target is at 8.0, project at 7.0, xcodebuild chooses the first
    // simulator on the list, iPad 2 7.1, which is invalid for the target.
    //
    // See https://github.com/Carthage/Carthage/issues/417.
    private static func fetchDestination(sdk: SDK) -> CarthageResult<String?> {
        // Specifying destination seems to be required for building with
        // simulator SDKs since Xcode 7.2.
        return destinationsCache.getValue(key: sdk) { sdk -> Result<String?, CarthageError> in
            if sdk.isSimulator {
                return Task("/usr/bin/xcrun", arguments: [ "simctl", "list", "devices", "--json" ])
                    .getStdOutData()
                    .mapError(CarthageError.taskError)
                    .flatMap { data -> Result<String?, CarthageError> in
                        if let selectedSimulator = Simulator.selectAvailableSimulator(of: sdk, from: data) {
                            return .success("platform=\(sdk.platform.rawValue) Simulator,id=\(selectedSimulator.udid.uuidString)")
                        } else {
                            return .failure(CarthageError.noAvailableSimulators(platformName: sdk.platform.rawValue))
                        }
                    }
            }
            return .success(nil)
        }
    }

    /// Runs the build for a given sdk and build arguments, optionally performing a clean first
    // swiftlint:disable:next static function_body_length
    private static func build(project: ProjectLocator, scheme: Scheme, sdk: SDK, options: BuildOptions, in workingDirectoryURL: URL) -> CarthageResult<[BuildSettings]> {
        
        return CarthageResult.catching {
        
            let argsForLoading = BuildArguments(
                project: project,
                scheme: scheme,
                configuration: options.configuration,
                derivedDataPath: options.derivedDataPath,
                sdk: sdk,
                toolchain: options.toolchain
            )
            
            var argsForBuilding = argsForLoading
            argsForBuilding.onlyActiveArchitecture = false
           
            if let destination = try fetchDestination(sdk: sdk).get() {
                argsForBuilding.destination = destination
                argsForBuilding.destinationTimeout = 10
            }
            
            let buildAction: BuildArguments.Action = .archive
            
            return try loadBuildSettings(with: argsForLoading, for: buildAction).get().reduce(into: [BuildSettings]()) { builtSettings, settings in
                guard settings.frameworkType.value != nil, let projectPath = settings.projectPath.value else {
                    return
                }
                
                // Do not copy build products that originate from the current project's own carthage dependencies
                let projectURL = URL(fileURLWithPath: projectPath)
                let dependencyCheckoutDir = workingDirectoryURL.appendingPathComponent(Constants.checkoutsPath, isDirectory: true)
                if dependencyCheckoutDir.hasSubdirectory(projectURL) {
                    return
                }
                
                try removeTargetBuildDirectory(for: settings).get()
            
                let xcodeBuildOptions = [
                    buildAction.rawValue,
                
                    // Prevent generating unnecessary empty `.xcarchive`
                    // directories.
                    "-archivePath", NSTemporaryDirectory().appendingPathComponent(workingDirectoryURL.lastPathComponent),

                    // Disable installing when running `archive` action
                    // to prevent built frameworks from being deleted
                    // from derived data folder.
                    "SKIP_INSTALL=YES",

                    // Disable the “Instrument Program Flow” build
                    // setting for both GCC and LLVM as noted in
                    // https://developer.apple.com/library/content/qa/qa1964/_index.html.
                    "GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO",

                    // Disable the “Generate Test Coverage Files” build
                    // setting for GCC as noted in
                    // https://developer.apple.com/library/content/qa/qa1964/_index.html.
                    "CLANG_ENABLE_CODE_COVERAGE=NO",

                    // Disable the "Strip Linked Product" build
                    // setting so we can later generate a dSYM
                    "STRIP_INSTALLED_PRODUCT=NO",
                    
                    // Enabled whole module compilation since we are not interested in incremental mode
                    "SWIFT_COMPILATION_MODE=wholemodule",
                ]
                
                var buildTask = xcodebuildTask(xcodeBuildOptions, argsForBuilding)
                buildTask.workingDirectoryPath = workingDirectoryURL.path
                
                try buildTask.launch()
                    .mapError(CarthageError.taskError)
                    .wait()
                    .get()
                
                builtSettings.append(settings)
            }
        }
    }

    /// Creates a dSYM for the provided dynamic framework.
    private static func createDebugInformation(_ builtProductURL: URL) -> CarthageResult<URL?> {
        let dSYMURL = builtProductURL.appendingPathExtension("dSYM")
        let executableName = builtProductURL.deletingPathExtension().lastPathComponent
        if !executableName.isEmpty {
            let executable = builtProductURL.appendingPathComponent(executableName).path
            let dSYM = dSYMURL.path
            let dsymutilTask = Task("/usr/bin/xcrun", arguments: ["dsymutil", executable, "-o", dSYM])
            return dsymutilTask.launch()
                .mapError(CarthageError.taskError)
                .wait()
                .map { _ in dSYMURL }
        } else {
            return .success(nil)
        }
    }

    /// Strips the given architecture from a framework.
    private static func stripArchitecture(_ frameworkURL: URL, _ architecture: String) -> CarthageResult<()> {
        return Frameworks.binaryURL(frameworkURL).flatMap { binaryURL in
            let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-remove", architecture, "-output", binaryURL.path, binaryURL.path])
            return lipoTask.launch()
                .mapError(CarthageError.taskError)
                .wait()
        }
    }

    /// Strips debug symbols from the given framework
    private static func stripDebugSymbols(_ frameworkURL: URL) -> CarthageResult<()> {
        return Frameworks.binaryURL(frameworkURL).flatMap { binaryURL in
            let stripTask = Task("/usr/bin/xcrun", arguments: [ "strip", "-S", "-o", binaryURL.path, binaryURL.path])
            return stripTask.launch()
                .mapError(CarthageError.taskError)
                .wait()
        }
    }

    /// Strips `Headers` directory from the given framework.
    private static func stripHeadersDirectory(_ frameworkURL: URL) -> CarthageResult<()> {
        return stripDirectory(named: "Headers", of: frameworkURL)
    }

    /// Strips `PrivateHeaders` directory from the given framework.
    private static func stripPrivateHeadersDirectory(_ frameworkURL: URL) -> CarthageResult<()> {
        return stripDirectory(named: "PrivateHeaders", of: frameworkURL)
    }

    /// Strips `Modules` directory from the given framework.
    private static func stripModulesDirectory(_ frameworkURL: URL) -> CarthageResult<()> {
        return stripDirectory(named: "Modules", of: frameworkURL)
    }

    private static func stripDirectory(named directory: String, of frameworkURL: URL) -> CarthageResult<()> {
        return CarthageResult.catching {
            let directoryURLToStrip = frameworkURL.appendingPathComponent(directory, isDirectory: true)
            guard directoryURLToStrip.isExistingDirectory else {
                return
            }
            try FileManager.default.removeItem(at: directoryURLToStrip)
        }
    }

    /// Signs a framework with the given codesigning identity.
    private static func codesign(_ frameworkURL: URL, _ expandedIdentity: String) -> CarthageResult<()> {
        let codesignTask = Task(
            "/usr/bin/xcrun",
            arguments: ["codesign", "--force", "--sign", expandedIdentity, "--preserve-metadata=identifier,entitlements", frameworkURL.path]
        )
        return codesignTask.launch()
            .mapError(CarthageError.taskError)
            .wait()
    }

    /// Determines which SDKs the given scheme builds for, by default.
    ///
    /// If an SDK is unrecognized or could not be determined, an error will be
    /// sent on the returned signal.
    private static func SDKsForScheme(_ scheme: Scheme, inProject project: ProjectLocator) -> CarthageResult<Set<SDK>> {
        return loadBuildSettings(with: BuildArguments(project: project, scheme: scheme))
                .reduce(into: Set<SDK>()) { set, settings in
                    if let sdks = settings.buildSDKs.value {
                        sdks.forEach { set.insert($0) }
                    }
                }
    }
}
