// swiftlint:disable file_length

import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD

/// A producer representing a scheme to be built.
///
/// A producer of this type will send the project and scheme name when building
/// begins, then complete or error when building terminates.
public typealias BuildSchemeProducer = SignalProducer<TaskEvent<(ProjectLocator, Scheme)>, CarthageError>

/// A callback static function used to determine whether or not an SDK should be built
public typealias SDKFilterCallback = (_ sdks: [SDK], _ scheme: Scheme, _ configuration: String, _ project: ProjectLocator) -> Result<[SDK], CarthageError>

public typealias ProjectBuildConfiguration = (scheme: Scheme, project: ProjectLocator, sdks: [SDK])

public final class Xcode {
    
    public static let defaultBuildConfiguration = "Release"
    
    /// Attempts to build the dependency, then places its build product into the
    /// root directory given.
    ///
    /// Returns producers in the same format as buildInDirectory().
    static func build(
        dependency: Dependency,
        version: PinnedVersion,
        rootDirectoryURL: URL,
        withOptions options: BuildOptions,
        resolvedDependencySet: Set<PinnedDependency>?,
        lockTimeout: Int? = nil,
        sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) },
        builtProductsHandler: (([URL]) -> SignalProducer<(), CarthageError>)? = nil
        ) -> BuildSchemeProducer {
        let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
        let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()

        return buildInDirectory(dependencyURL,
                                withOptions: options,
                                dependency: (dependency, version),
                                rootDirectoryURL: rootDirectoryURL,
                                resolvedDependencySet: resolvedDependencySet,
                                lockTimeout: lockTimeout,
                                sdkFilter: sdkFilter,
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
        resolvedDependencySet: Set<PinnedDependency>?,
        lockTimeout: Int? = nil,
        customProjectName: String? = nil,
        customCommitish: String? = nil,
        sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) },
        builtProductsHandler: (([URL]) -> SignalProducer<(), CarthageError>)? = nil
        ) -> BuildSchemeProducer {
        precondition(directoryURL.isFileURL)

        var lock: Lock?
        return URLLock.lockReactive(url: URL(fileURLWithPath: options.derivedDataPath), timeout: lockTimeout, recursive: true)
            .flatMap(.merge) { urlLock -> BuildSchemeProducer in
                lock = urlLock
                
                let removeDerivedDataDir = SignalProducer<(), CarthageError> { () -> Result<(), CarthageError> in
                    URL(fileURLWithPath: options.derivedDataPath).removeIgnoringErrors()
                    return .success(())
                }

                let buildSchemes = BuildSchemeProducer { observer, lifetime in
                    buildableSchemesInDirectory(directoryURL,
                                                withConfiguration: options.configuration,
                                                forPlatforms: options.platforms
                        )
                        .flatMap(.concat) { (scheme: Scheme, project: ProjectLocator) -> SignalProducer<TaskEvent<URL>, CarthageError> in
                            let initialValue = (project, scheme)

                            let wrappedSDKFilter: SDKFilterCallback = { sdks, scheme, configuration, project in
                                let filteredSDKs: [SDK]
                                if options.platforms.isEmpty {
                                    filteredSDKs = sdks
                                } else {
                                    filteredSDKs = sdks.filter { options.platforms.contains($0.platform) }
                                }
                                return sdkFilter(filteredSDKs, scheme, configuration, project)
                            }

                            return buildScheme(
                                scheme,
                                withOptions: options,
                                inProject: project,
                                rootDirectoryURL: rootDirectoryURL,
                                workingDirectoryURL: directoryURL,
                                sdkFilter: wrappedSDKFilter
                                )
                                .mapError { error -> CarthageError in
                                    if case let .taskError(taskError) = error {
                                        return .buildFailed(taskError, log: nil)
                                    } else {
                                        return error
                                    }
                                }
                                .on(started: {
                                    observer.send(value: .success(initialValue))
                                })
                        }
                        .collectTaskEvents()
                        .flatMapTaskEvents(.concat) { (urls: [URL]) -> SignalProducer<(), CarthageError> in
                            if let dependency = dependency {
                                return VersionFile.createVersionFile(
                                    for: dependency.dependency,
                                    version: dependency.version,
                                    platforms: options.platforms,
                                    configuration: options.configuration,
                                    resolvedDependencySet: resolvedDependencySet,
                                    buildProducts: urls,
                                    rootDirectoryURL: rootDirectoryURL
                                    ).then(builtProductsHandler?(urls) ?? SignalProducer<(), CarthageError>.empty)
                            } else {
                                // Is only possible if the current project is a git repository, because the version file is tied to commit hash
                                if rootDirectoryURL.isGitDirectory {
                                    return VersionFile.createVersionFileForCurrentProject(
                                        projectName: customProjectName, 
                                        commitish: customCommitish,
                                        platforms: options.platforms,
                                        configuration: options.configuration,
                                        resolvedDependencySet: resolvedDependencySet,
                                        buildProducts: urls,
                                        rootDirectoryURL: rootDirectoryURL
                                        ).then(builtProductsHandler?(urls) ?? SignalProducer<(), CarthageError>.empty)
                                } else {
                                    return builtProductsHandler?(urls) ?? SignalProducer<(), CarthageError>.empty
                                }
                            }
                        }
                        // Discard any Success values, since we want to
                        // use our initial value instead of waiting for
                        // completion.
                        .map { taskEvent -> TaskEvent<(ProjectLocator, Scheme)> in
                            let ignoredValue = (ProjectLocator.workspace(URL(string: ".")!), Scheme(""))
                            return taskEvent.map { _ in ignoredValue }
                        }
                        .filter { taskEvent in
                            taskEvent.value == nil
                        }
                        .startWithSignal({ signal, signalDisposable in
                            lifetime += signalDisposable
                            signal.observe(observer)
                        })
                }
                
                return removeDerivedDataDir.then(buildSchemes)
                
            }.on(terminated: {
                lock?.unlock()
            })
    }
    
    public static func generateProjectCartfile(directoryURL: URL, observer: ((ProjectBuildConfiguration) -> Void)? = nil) -> SignalProducer<ProjectCartfile, CarthageError> {
        let configuration = Xcode.defaultBuildConfiguration
        return discoverBuildableSchemes(directoryURL: directoryURL, configuration: configuration, platforms: Set())
            .flatMap(.concat) { entry -> SignalProducer<ProjectBuildConfiguration, CarthageError> in
                let (scheme, project) = entry
                
                let buildArgs = BuildArguments(
                    project: project,
                    scheme: scheme,
                    configuration: configuration,
                    derivedDataPath: Constants.Dependency.derivedDataURL.path
                )
                
                let sdkResult = discoverSDKs(buildArgs: buildArgs).collect().single()!
                return SignalProducer(result: sdkResult).map {
                    let config = (scheme, project, $0)
                    observer?(config)
                    return config
                }
            }
            .reduce(into: [String: SchemeConfiguration](), { dict, entry in
                let (scheme, project, sdks) = entry
                guard let relativePath = project.fileURL.pathRelativeTo(directoryURL) else {
                    fatalError("Expected path of project to be relative to directoryURL")
                }
                dict[scheme.name] = SchemeConfiguration(project: relativePath, sdks: sdks.unique())
            })
            .map { dict -> ProjectCartfile in
                return ProjectCartfile(schemeConfigurations: dict)
            }
            .flatMapError { error -> SignalProducer<ProjectCartfile, CarthageError> in
                switch error {
                case .noSharedFrameworkSchemes, .noSharedSchemes:
                    return SignalProducer(result: ProjectCartfile.from(string: ""))
                default:
                    return SignalProducer(error: error)
                }
            }
    }

    /// Finds schemes of projects or workspaces, which Carthage should build, found
    /// within the given directory.
    static func buildableSchemesInDirectory( // swiftlint:disable:this static function_body_length
        _ directoryURL: URL,
        withConfiguration configuration: String,
        forPlatforms platforms: Set<Platform> = []
        ) -> SignalProducer<(Scheme, ProjectLocator), CarthageError> {
        precondition(directoryURL.isFileURL)
        
        // Try to read the Cartfile.project. If it exists use that, otherwise revert to the old (slow!!!) way of auto-discovery
        let projectCartfileURL = ProjectCartfile.url(in: directoryURL)
        if projectCartfileURL.isExistingFile {
            return SignalProducer<ProjectCartfile, CarthageError>(result: ProjectCartfile.from(fileURL: projectCartfileURL))
                .flatMap(.merge) { projectCartfile -> SignalProducer<(Scheme, ProjectLocator), CarthageError> in
                    let projectSchemes = Result<[(Scheme, ProjectLocator)], CarthageError>.init(catching: {
                        return try projectCartfile.schemeConfigurations.map { entry in
                            guard let project = entry.value.projectLocator(in: directoryURL) else {
                                throw CarthageError.internalError(description: "Invalid \(Constants.Project.projectCartfilePath): a project should have an extension of .xcodeproj or .xcworkspace, but found: \(entry.value.project)")
                            }
                            return (Scheme(entry.key), project)
                        }
                    })
                    return SignalProducer(result: projectSchemes).flatten()
                }
        }
        return discoverBuildableSchemes(directoryURL: directoryURL, configuration: configuration, platforms: platforms)
    }
    
    private static func discoverBuildableSchemes(directoryURL: URL, configuration: String, platforms: Set<Platform>) -> SignalProducer<(Scheme, ProjectLocator), CarthageError> {
        let schemeMatcher = SchemeCartfile.from(directoryURL: directoryURL).value?.matcher
        let locator = ProjectLocator
            .locate(in: directoryURL)
            .flatMap(.concat) { project -> SignalProducer<(ProjectLocator, [Scheme]), CarthageError> in
                return project
                    .schemes()
                    .collect()
                    .flatMapError { error in
                        if case .noSharedSchemes = error {
                            return .init(value: [])
                        } else {
                            return .init(error: error)
                        }
                    }
                    .map { (project, $0) }
            }
        return locator
            .collect()
            // Allow dependencies which have no projects, not to error out with
            // `.noSharedFrameworkSchemes`.
            .filter { projects in !projects.isEmpty }
            .flatMap(.merge) { (projects: [(ProjectLocator, [Scheme])]) -> SignalProducer<(Scheme, ProjectLocator), CarthageError> in
                return schemesInProjects(projects).flatten()
            }
            .flatMap(.concurrent(limit: Constants.concurrencyLimit)) { scheme, project -> SignalProducer<(Scheme, ProjectLocator), CarthageError> in
                /// Check whether we should the scheme by checking against the project. If we're building
                /// from a workspace, then it might include additional targets that would trigger our
                /// check.
                let buildArguments = BuildArguments(project: project, scheme: scheme, configuration: configuration)
                return shouldBuildScheme(buildArguments, forPlatforms: platforms, schemeMatcher: schemeMatcher)
                    .filter { $0 }
                    .map { _ in (scheme, project) }
            }
            .flatMap(.concurrent(limit: Constants.concurrencyLimit)) { scheme, project -> SignalProducer<(Scheme, ProjectLocator), CarthageError> in
                return locator
                    // This scheduler hop is required to avoid disallowed recursive signals.
                    // See https://github.com/ReactiveCocoa/ReactiveCocoa/pull/2042.
                    .start(on: QueueScheduler(qos: .default, name: "org.carthage.CarthageKit.Xcode.buildInDirectory"))
                    // Pick up the first workspace which can build the scheme.
                    .flatMap(.concat) { project, schemes -> SignalProducer<ProjectLocator, CarthageError> in
                        switch project {
                        case .workspace where schemes.contains(scheme):
                            let buildArguments = BuildArguments(project: project, scheme: scheme, configuration: configuration)
                            return shouldBuildScheme(buildArguments, forPlatforms: platforms, schemeMatcher: schemeMatcher)
                                .filter { $0 }
                                .map { _ in project }
                            
                        default:
                            return .empty
                        }
                    }
                    // If there is no appropriate workspace, use the project in
                    // which the scheme is defined instead.
                    .concat(value: project)
                    .take(first: 1)
                    .map { project in (scheme, project) }
            }
            .collect()
            .flatMap(.merge) { (schemes: [(Scheme, ProjectLocator)]) -> SignalProducer<(Scheme, ProjectLocator), CarthageError> in
                if !schemes.isEmpty {
                    return .init(schemes)
                } else {
                    return .init(error: .noSharedFrameworkSchemes(.git(GitURL(directoryURL.path)), platforms))
                }
        }
    }

    /// Sends each shared scheme name found in the receiver.
    static func listSchemeNames(project: ProjectLocator) -> SignalProducer<String, CarthageError> {
        let task = xcodebuildTask("-list", BuildArguments(project: project), useCache: true)

        return task.launch()
            .ignoreTaskData()
            .mapError(CarthageError.taskError)
            // xcodebuild has a bug where xcodebuild -list can sometimes hang
            // indefinitely on projects that don't share any schemes, so
            // automatically bail out if it looks like that's happening.
            .timeout(after: 60, raising: .xcodebuildTimeout(project), on: QueueScheduler())
            .retry(upTo: 2)
            .map { data in
                return String(data: data, encoding: .utf8)!
            }
            .flatMap(.merge) { string in
                return string.linesProducer
            }
            .flatMap(.merge) { line -> SignalProducer<String, CarthageError> in
                // Matches one of these two possible messages:
                //
                // '    This project contains no schemes.'
                // 'There are no schemes in workspace "Carthage".'
                if line.hasSuffix("contains no schemes.") || line.hasPrefix("There are no schemes") {
                    return SignalProducer(error: CarthageError.noSharedSchemes(project, nil))
                } else {
                    return SignalProducer(value: line)
                }
            }
            .skip { line in !line.hasSuffix("Schemes:") }
            .skip(first: 1)
            .take { line in !line.isEmpty }
    }

    /// Invokes `xcodebuild` to retrieve build settings for the given build
    /// arguments.
    ///
    /// Upon .success, sends one BuildSettings value for each target included in
    /// the referenced scheme.
    static func loadBuildSettings(with arguments: BuildArguments, for action: BuildArguments.Action? = nil) -> SignalProducer<BuildSettings, CarthageError> {
        // xcodebuild (in Xcode 8.0) has a bug where xcodebuild -showBuildSettings
        // can hang indefinitely on projects that contain core data models.
        // rdar://27052195
        // Including the action "clean" works around this issue, which is further
        // discussed here: https://forums.developer.apple.com/thread/50372
        //
        // "archive" also works around the issue above so use it to determine if
        // it is configured for the archive action.
        let task = xcodebuildTask(["archive", "-showBuildSettings", "-skipUnavailableActions"], arguments, useCache: true)

        return task.launch()
            .ignoreTaskData()
            .mapError(CarthageError.taskError)
            // xcodebuild has a bug where xcodebuild -showBuildSettings
            // can sometimes hang indefinitely on projects that don't
            // share any schemes, so automatically bail out if it looks
            // like that's happening.
            .timeout(after: 60, raising: .xcodebuildTimeout(arguments.project), on: QueueScheduler(qos: .default))
            .retry(upTo: 5)
            .map { data in
                return String(data: data, encoding: .utf8)!
            }
            .flatMap(.merge) { string -> SignalProducer<BuildSettings, CarthageError> in
                BuildSettings.produce(string: string, arguments: arguments, action: action)
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
        ) -> SignalProducer<(), CarthageError> {

        let stripArchitectures = stripBinary(frameworkURL, keepingArchitectures: keepingArchitectures)
        let stripSymbols = strippingDebugSymbols ? stripDebugSymbols(frameworkURL) : .empty

        // Xcode doesn't copy `Headers`, `PrivateHeaders` and `Modules` directory at
        // all.
        let stripHeaders = stripHeadersDirectory(frameworkURL)
        let stripPrivateHeaders = stripPrivateHeadersDirectory(frameworkURL)
        let stripModules = stripModulesDirectory(frameworkURL)

        let sign = codesigningIdentity.map { codesign(frameworkURL, $0) } ?? .empty

        return stripArchitectures
            .concat(stripSymbols)
            .concat(stripHeaders)
            .concat(stripPrivateHeaders)
            .concat(stripModules)
            .concat(sign)
    }

    /// Strips a universal file from unexpected architectures.
    static func stripBinary(_ binaryURL: URL, keepingArchitectures: [String]) -> SignalProducer<(), CarthageError> {
        return Frameworks.architecturesInPackage(binaryURL)
            .filter { !keepingArchitectures.contains($0) }
            .flatMap(.concat) { stripArchitecture(binaryURL, $0) }
    }

    // MARK: - Private

    /// Creates a task description for executing `xcodebuild` with the given
    /// arguments.
    private static func xcodebuildTask(_ tasks: [String], _ buildArguments: BuildArguments, workingDirectoryPath: String? = nil, useCache: Bool = false) -> Task {
        return Task("/usr/bin/xcrun", arguments: buildArguments.arguments + tasks, workingDirectoryPath: workingDirectoryPath, useCache: useCache)
    }

    /// Creates a task description for executing `xcodebuild` with the given
    /// arguments.
    private static func xcodebuildTask(_ task: String, _ buildArguments: BuildArguments, workingDirectoryPath: String? = nil, useCache: Bool = false) -> Task {
        return xcodebuildTask([task], buildArguments, workingDirectoryPath: workingDirectoryPath, useCache: useCache)
    }

    /// Sends pairs of a scheme and a project, the scheme actually resides in
    /// the project.
    private static func schemesInProjects(_ projects: [(ProjectLocator, [Scheme])]) -> SignalProducer<[(Scheme, ProjectLocator)], CarthageError> {
        return SignalProducer<(ProjectLocator, [Scheme]), CarthageError>(projects)
            .map { (project: ProjectLocator, schemes: [Scheme]) in
                // Only look for schemes that actually reside in the project
                let containedSchemes = schemes.filter { scheme -> Bool in
                    let schemePath = project.fileURL.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme").path
                    return FileManager.default.fileExists(atPath: schemePath)
                }
                return (project, containedSchemes)
            }
            .filter { (project: ProjectLocator, schemes: [Scheme]) in
                switch project {
                case .projectFile where !schemes.isEmpty:
                    return true

                default:
                    return false
                }
            }
            .flatMap(.concat) { project, schemes in
                return SignalProducer<(Scheme, ProjectLocator), CarthageError>(schemes.map { ($0, project) })
            }
            .collect()
    }

    /// Finds the built product for the given settings, then copies it (preserving
    /// its name) into the given folder. The folder will be created if it does not
    /// already exist.
    ///
    /// If this built product has any *.bcsymbolmap files they will also be copied.
    ///
    /// Returns a signal that will send the URL after copying upon .success.
    private static func copyBuildProductIntoDirectory(_ directoryURL: URL, _ settings: BuildSettings) -> SignalProducer<URL, CarthageError> {
        let target = settings.wrapperName.map(directoryURL.appendingPathComponent)
        return SignalProducer(result: target.fanout(settings.wrapperURL))
            .flatMap(.merge) { target, source in
                return Files.copyFile(from: source.resolvingSymlinksInPath(), to: target)
            }
            .flatMap(.merge) { url in
                return copyBCSymbolMapsForBuildProductIntoDirectory(directoryURL, settings)
                    .then(SignalProducer<URL, CarthageError>(value: url))
        }
    }

    /// Finds any *.bcsymbolmap files for the built product and copies them into
    /// the given folder. Does nothing if bitcode is disabled.
    ///
    /// Returns a signal that will send the URL after copying for each file.
    private static func copyBCSymbolMapsForBuildProductIntoDirectory(_ directoryURL: URL, _ settings: BuildSettings) -> SignalProducer<URL, CarthageError> {
        if settings.bitcodeEnabled.value == true {
            return SignalProducer(result: settings.wrapperURL)
                .flatMap(.merge) { wrapperURL in Frameworks.BCSymbolMapsForFramework(wrapperURL) }
                .copyFileURLsIntoDirectory(directoryURL)
        } else {
            return .empty
        }
    }

    /// Attempts to merge the given executables into one fat binary, written to
    /// the specified URL.
    private static func mergeExecutables(_ executableURLs: [URL], _ outputURL: URL) -> SignalProducer<(), CarthageError> {
        precondition(outputURL.isFileURL)

        return SignalProducer<URL, CarthageError>(executableURLs)
            .attemptMap { url -> Result<String, CarthageError> in
                if url.isFileURL {
                    return .success(url.path)
                } else {
                    return .failure(.parseError(description: "expected file URL to built executable, got \(url)"))
                }
            }
            .collect()
            .flatMap(.merge) { executablePaths -> SignalProducer<TaskEvent<Data>, CarthageError> in
                let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-create" ] + executablePaths + [ "-output", outputURL.path ])

                return lipoTask.launch()
                    .mapError(CarthageError.taskError)
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }

    private static func mergeSwiftHeaderFiles(_ simulatorExecutableURL: URL,
                                              _ deviceExecutableURL: URL,
                                              _ executableOutputURL: URL) -> SignalProducer<(), CarthageError> {
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

        guard let simulatorHeaderURL = simulatorExecutableURL.deletingLastPathComponent().swiftHeaderURL() else { return .empty }
        guard let simulatorHeaderContents = FileManager.default.contents(atPath: simulatorHeaderURL.path) else { return .empty }
        guard let deviceHeaderURL = deviceExecutableURL.deletingLastPathComponent().swiftHeaderURL() else { return .empty }
        guard let deviceHeaderContents = FileManager.default.contents(atPath: deviceHeaderURL.path) else { return .empty }
        guard let outputURL = executableOutputURL.deletingLastPathComponent().swiftHeaderURL() else { return .empty }

        var fileContents = Data()

        fileContents.append(includeTargetConditionalsContents)
        fileContents.append(conditionalPrefixContents)
        fileContents.append(simulatorHeaderContents)
        fileContents.append(conditionalElseContents)
        fileContents.append(deviceHeaderContents)
        fileContents.append(conditionalSuffixContents)

        if FileManager.default.createFile(atPath: outputURL.path, contents: fileContents) {
            return .empty
        } else {
            return .init(error: .writeFailed(outputURL, nil))
        }
    }

    /// If the given source URL represents an LLVM module, copies its contents into
    /// the destination module.
    ///
    /// Sends the URL to each file after copying.
    private static func mergeModuleIntoModule(_ sourceModuleDirectoryURL: URL, _ destinationModuleDirectoryURL: URL) -> SignalProducer<URL, CarthageError> {
        precondition(sourceModuleDirectoryURL.isFileURL)
        precondition(destinationModuleDirectoryURL.isFileURL)

        return FileManager.default.reactive
            .enumerator(at: sourceModuleDirectoryURL, includingPropertiesForKeys: [], options: [ .skipsSubdirectoryDescendants, .skipsHiddenFiles ], catchErrors: true)
            .attemptMap { _, url -> Result<URL, CarthageError> in
                let lastComponent = url.lastPathComponent
                let destinationURL = destinationModuleDirectoryURL.appendingPathComponent(lastComponent).resolvingSymlinksInPath()

                return Result(at: destinationURL, attempt: {
                    try FileManager.default.copyItem(at: url, to: $0, avoiding·rdar·32984063: true)
                    return $0
                })
        }
    }

    /// Determines whether the specified framework type should be built automatically.
    private static func shouldBuildFrameworkType(_ frameworkType: FrameworkType?) -> Bool {
        return frameworkType != nil
    }

    /// Determines whether the given scheme should be built automatically.
    private static func shouldBuildScheme(_ buildArguments: BuildArguments, forPlatforms: Set<Platform>, schemeMatcher: SchemeMatcher?) -> SignalProducer<Bool, CarthageError> {
        precondition(buildArguments.scheme != nil)

        guard schemeMatcher?.matches(scheme: buildArguments.scheme!) ?? true else {
            return SignalProducer(value: false)
        }

        return loadBuildSettings(with: buildArguments)
            .flatMap(.concat) { settings -> SignalProducer<FrameworkType?, CarthageError> in
                let frameworkType = SignalProducer(result: settings.frameworkType)

                if forPlatforms.isEmpty {
                    return frameworkType
                        .flatMapError { _ in .empty }
                } else {
                    return settings.buildSDKs
                        .filter { forPlatforms.contains($0.platform) }
                        .flatMap(.merge) { _ in frameworkType }
                        .flatMapError { _ in .empty }
                }
            }
            .filter(shouldBuildFrameworkType)
            // If we find any framework target, we should indeed build this scheme.
            .map { _ in true }
            // Otherwise, nope.
            .concat(value: false)
            .take(first: 1)
    }

    /// Aggregates all of the build settings sent on the given signal, associating
    /// each with the name of its target.
    ///
    /// Returns a signal which will send the aggregated dictionary upon completion
    /// of the input signal, then itself complete.
    private static func settingsByTarget<Error>(_ producer: SignalProducer<TaskEvent<BuildSettings>, Error>) -> SignalProducer<TaskEvent<[String: BuildSettings]>, Error> {
        return SignalProducer { observer, lifetime in
            var settings: [String: BuildSettings] = [:]

            producer.startWithSignal { signal, signalDisposable in
                lifetime += signalDisposable

                signal.observe { event in
                    switch event {
                    case let .value(settingsEvent):
                        let transformedEvent = settingsEvent.map { settings in [ settings.target: settings ] }

                        if let transformed = transformedEvent.value {
                            settings.merge(transformed) { _, new in new }
                        } else {
                            observer.send(value: transformedEvent)
                        }

                    case let .failed(error):
                        observer.send(error: error)

                    case .completed:
                        observer.send(value: .success(settings))
                        observer.sendCompleted()

                    case .interrupted:
                        observer.sendInterrupted()
                    }
                }
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
        ) -> SignalProducer<URL, CarthageError> {
        return copyBuildProductIntoDirectory(destinationFolderURL, deviceBuildSettings)
            .flatMap(.merge) { productURL -> SignalProducer<URL, CarthageError> in
                let executableURLs = (deviceBuildSettings.executableURL.fanout(simulatorBuildSettings.executableURL)).map { [ $0, $1 ] }
                let outputURL = deviceBuildSettings.executablePath.map(destinationFolderURL.appendingPathComponent)

                let mergeProductBinaries = SignalProducer(result: executableURLs.fanout(outputURL))
                    .flatMap(.concat) { (executableURLs: [URL], outputURL: URL) -> SignalProducer<(), CarthageError> in
                        return mergeExecutables(
                            executableURLs.map { $0.resolvingSymlinksInPath() },
                            outputURL.resolvingSymlinksInPath()
                        )
                }

                let mergeProductSwiftHeaderFilesIfNeeded = SignalProducer.zip(simulatorBuildSettings.executableURL, deviceBuildSettings.executableURL, outputURL)
                    .flatMap(.concat) { (simulatorURL: URL, deviceURL: URL, outputURL: URL) -> SignalProducer<(), CarthageError> in
                        guard Frameworks.isSwiftFramework(productURL) else { return .empty }

                        return mergeSwiftHeaderFiles(
                            simulatorURL.resolvingSymlinksInPath(),
                            deviceURL.resolvingSymlinksInPath(),
                            outputURL.resolvingSymlinksInPath()
                        )
                }

                let sourceModulesURL = SignalProducer(result: simulatorBuildSettings.relativeModulesPath.fanout(simulatorBuildSettings.builtProductsDirectoryURL))
                    .filter { $0.0 != nil }
                    .map { modulesPath, productsURL in
                        return productsURL.appendingPathComponent(modulesPath!)
                }

                let destinationModulesURL = SignalProducer(result: deviceBuildSettings.relativeModulesPath)
                    .filter { $0 != nil }
                    .map { modulesPath -> URL in
                        return destinationFolderURL.appendingPathComponent(modulesPath!)
                }

                let mergeProductModules = SignalProducer.zip(sourceModulesURL, destinationModulesURL)
                    .flatMap(.merge) { (source: URL, destination: URL) -> SignalProducer<URL, CarthageError> in
                        return mergeModuleIntoModule(source, destination)
                }

                return mergeProductBinaries
                    .then(mergeProductSwiftHeaderFilesIfNeeded)
                    .then(mergeProductModules)
                    .then(copyBCSymbolMapsForBuildProductIntoDirectory(destinationFolderURL, simulatorBuildSettings))
                    .then(SignalProducer<URL, CarthageError>(value: productURL))
        }
    }

    /// Builds one scheme of the given project, for all supported SDKs.
    ///
    /// Returns a signal of all standard output from `xcodebuild`, and a signal
    /// which will send the URL to each product successfully built.
    private static func buildScheme( // swiftlint:disable:this static function_body_length cyclomatic_complexity
        _ scheme: Scheme,
        withOptions options: BuildOptions,
        inProject project: ProjectLocator,
        rootDirectoryURL: URL,
        workingDirectoryURL: URL,
        sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) }
        ) -> SignalProducer<TaskEvent<URL>, CarthageError> {
        precondition(workingDirectoryURL.isFileURL)

        let buildArgs = BuildArguments(
            project: project,
            scheme: scheme,
            configuration: options.configuration,
            derivedDataPath: options.derivedDataPath,
            toolchain: options.toolchain,
            buildForDistribution: options.buildForDistribution,
            validDestinationIdentifiers: options.validSimulatorIdentifierSet
        )
        
        // If the Cartfile.project exists use that instead of trying to auto-discover the SDKs based on the build settings
        let sdkProducer: SignalProducer<SDK, CarthageError>
        
        let projectCartfileURL = ProjectCartfile.url(in: workingDirectoryURL)
        if projectCartfileURL.isExistingFile {
            sdkProducer = SignalProducer<ProjectCartfile, CarthageError>(result: ProjectCartfile.from(fileURL: projectCartfileURL))
            .flatMap(.merge) { projectCartfile -> SignalProducer<SDK, CarthageError> in
                guard let sdks = projectCartfile.schemeConfigurations[scheme.name]?.sdks else {
                    return SignalProducer(error: CarthageError.internalError(description: "No definition found in \(Constants.Project.projectCartfilePath) for scheme: \(scheme.name)"))
                }
                return SignalProducer(sdks)
            }
        } else {
            sdkProducer = discoverSDKs(buildArgs: buildArgs)
        }
        
        return sdkProducer
            .reduce(into: [:]) { (sdksByPlatform: inout [Platform: Set<SDK>], sdk: SDK) in
                let platform = sdk.platform

                if var sdks = sdksByPlatform[platform] {
                    sdks.insert(sdk)
                    sdksByPlatform.updateValue(sdks, forKey: platform)
                } else {
                    sdksByPlatform[platform] = [sdk]
                }
            }
            .flatMap(.concat) { sdksByPlatform -> SignalProducer<(Platform, [SDK]), CarthageError> in
                if sdksByPlatform.isEmpty {
                    return SignalProducer(error: CarthageError.internalError(description: "No SDKs found for scheme \(scheme)"))
                }

                let values = sdksByPlatform.map { ($0, Array($1)) }
                return SignalProducer(values)
            }
            .flatMap(.concat) { platform, sdks -> SignalProducer<(Platform, [SDK]), CarthageError> in
                let filterResult = sdkFilter(sdks, scheme, options.configuration, project)
                return SignalProducer(result: filterResult.map { (platform, $0) })
            }
            .filter { _, sdks in
                return !sdks.isEmpty
            }
            .flatMap(.concat) { platform, sdks -> SignalProducer<TaskEvent<URL>, CarthageError> in
                let folderURL = rootDirectoryURL.appendingPathComponent(platform.relativePath, isDirectory: true).resolvingSymlinksInPath()

                switch sdks.count {
                case 1:
                    return build(sdk: sdks[0], with: buildArgs, in: workingDirectoryURL)
                        .flatMapTaskEvents(.merge) { settings in
                            return copyBuildProductIntoDirectory(settings.productDestinationPath(in: folderURL), settings)
                    }

                case 2:
                    let (simulatorSDKs, deviceSDKs) = SDK.splitSDKs(sdks)
                    guard deviceSDKs.first != nil else {
                        return SignalProducer(error: CarthageError.internalError(description: "Could not find device SDK in \(sdks)"))
                    }
                    guard simulatorSDKs.first != nil else {
                        return SignalProducer(error: CarthageError.internalError(description: "Could not find simulator SDK in \(sdks)"))
                    }
                    
                    return SignalProducer(sdks)
                        .flatMap(.concat) { sdk -> SignalProducer<TaskEvent<(sdk: SDK, settings: BuildSettings)>, CarthageError> in
                            return build(sdk: sdk, with: buildArgs, in: workingDirectoryURL).map { event in
                                return event.map { (sdk, $0) }
                            }
                        }
                        .collectTaskEvents()
                        .flatMapTaskEvents(.concat) { allSettings -> SignalProducer<(BuildSettings, BuildSettings), CarthageError> in
                            var deviceSettingsByTarget = [String: BuildSettings]()
                            var simulatorSettingsByTarget = [String: BuildSettings]()
                            for settings in allSettings {
                                if settings.sdk.isDevice {
                                    deviceSettingsByTarget[settings.settings.target] = settings.settings
                                } else if settings.sdk.isSimulator {
                                    simulatorSettingsByTarget[settings.settings.target] = settings.settings
                                }
                            }
                            
                            var settingsTuples = [(BuildSettings, BuildSettings)]()
                            for entry in deviceSettingsByTarget {
                                let deviceSettings = entry.value
                                guard let simulatorSettings = simulatorSettingsByTarget[entry.key] else {
                                    return SignalProducer(error: CarthageError.internalError(description: "No simulator build settings found for target \"\(entry.key)\""))
                                }
                                settingsTuples.append((deviceSettings, simulatorSettings))
                            }
                            return SignalProducer(settingsTuples)
                        }
                        .flatMapTaskEvents(.concat) { deviceSettings, simulatorSettings in
                                return mergeBuildProducts(
                                    deviceBuildSettings: deviceSettings,
                                    simulatorBuildSettings: simulatorSettings,
                                    into: deviceSettings.productDestinationPath(in: folderURL)
                                )
                        }
                default:
                    return SignalProducer(error: CarthageError.internalError(description: "SDK count \(sdks.count) in scheme \(scheme) is not supported"))
                }
            }
            .flatMapTaskEvents(.concat) { builtProductURL -> SignalProducer<URL, CarthageError> in
                return Frameworks.UUIDsForFramework(builtProductURL)
                    // Only attempt to create debug info if there is at least
                    // one dSYM architecture UUID in the framework. This can
                    // occur if the framework is a static framework packaged
                    // like a dynamic framework.
                    .take(first: 1)
                    .flatMap(.concat) { _ -> SignalProducer<TaskEvent<URL>, CarthageError> in
                        return createDebugInformation(builtProductURL)
                    }
                    .then(SignalProducer<URL, CarthageError>(value: builtProductURL))
        }
    }

    /// Fixes problem when more than one xcode target has the same Product name for same Deployment target and configuration by deleting TARGET_BUILD_DIR.
    private static func resolveSameTargetName(for settings: BuildSettings) -> SignalProducer<BuildSettings, CarthageError> {
        switch settings.targetBuildDirectory {
        case .success(let buildDir):
            let result = Task("/usr/bin/xcrun", arguments: ["rm", "-rf", buildDir])
                .launch()
                .wait()

            if let error = result.error {
                return SignalProducer(error: CarthageError.taskError(error))
            }

            return SignalProducer(value: settings)
        case .failure(let error):
            return SignalProducer(error: error)
        }
    }
    
    private static func discoverSDKs(buildArgs: BuildArguments) -> SignalProducer<SDK, CarthageError> {
        assert(buildArgs.scheme != nil, "Expected scheme to be supplied")
        let project = buildArgs.project
        guard let scheme = buildArgs.scheme else {
            return SignalProducer(error: CarthageError.internalError(description: "Scheme was not supplied which is required for discovery of compatible SDKs"))
        }
        return loadBuildSettings(with: BuildArguments(project: project, scheme: scheme))
            .take(first: 1)
            .flatMap(.merge) { $0.buildSDKs }
            .flatMap(.concat) { sdk -> SignalProducer<SDK, CarthageError> in
                var argsForLoading = buildArgs
                argsForLoading.sdk = sdk
                
                return loadBuildSettings(with: argsForLoading)
                    .filter { settings in
                        // Filter out SDKs that require bitcode when bitcode is disabled in
                        // project settings. This is necessary for testing frameworks, which
                        // must add a User-Defined setting of ENABLE_BITCODE=NO.
                        return settings.bitcodeEnabled.value == true || ![.tvOS, .watchOS].contains(sdk)
                    }
                    .map { _ in sdk }
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
    private static func fetchDestination(sdk: SDK, buildArgs: BuildArguments) -> SignalProducer<String?, CarthageError> {
        // Specifying destination seems to be required for building with
        // simulator SDKs since Xcode 7.2.
        if sdk.isSimulator {
            let destinationLookup = Task("/usr/bin/xcrun", arguments: [ "simctl", "list", "devices", "--json" ], useCache: true)
            return destinationLookup.launch()
                .mapError(CarthageError.taskError)
                .ignoreTaskData()
                .flatMap(.concat) { (data: Data) -> SignalProducer<Simulator, CarthageError> in
                    if let selectedSimulator = Simulator.selectAvailableSimulator(of: sdk, from: data, validIdentifiers: buildArgs.validDestinationIdentifiers) {
                        return .init(value: selectedSimulator)
                    } else {
                        return .init(error: CarthageError.noAvailableSimulators(platformName: sdk.platform.rawValue))
                    }
                }
                .map { "platform=\(sdk.platform.rawValue) Simulator,id=\($0.udid.uuidString)" }
        }
        return SignalProducer(value: nil)
    }

    /// Runs the build for a given sdk and build arguments, optionally performing a clean first
    // swiftlint:disable:next static function_body_length
    private static func build(sdk: SDK, with buildArgs: BuildArguments, in workingDirectoryURL: URL) -> SignalProducer<TaskEvent<BuildSettings>, CarthageError> {
        var argsForLoading = buildArgs
        argsForLoading.sdk = sdk

        var argsForBuilding = argsForLoading
        argsForBuilding.onlyActiveArchitecture = false

        return fetchDestination(sdk: sdk, buildArgs: buildArgs)
            .flatMap(.concat) { destination -> SignalProducer<TaskEvent<BuildSettings>, CarthageError> in
                if let destination = destination {
                    argsForBuilding.destination = destination
                }

                // Use `archive` action when building device SDKs to disable LLVM Instrumentation.
                //
                // See https://github.com/Carthage/Carthage/issues/2056
                // and https://developer.apple.com/library/content/qa/qa1964/_index.html.
                let xcodebuildAction: BuildArguments.Action = sdk.isDevice ? .archive : .build
                return loadBuildSettings(with: argsForLoading, for: xcodebuildAction)
                    .filter { settings in
                        // Only copy build products that are frameworks
                        guard let frameworkType = settings.frameworkType.value, shouldBuildFrameworkType(frameworkType), let projectPath = settings.projectPath.value else {
                            return false
                        }

                        // Do not copy build products that originate from the current project's own carthage dependencies
                        let projectURL = URL(fileURLWithPath: projectPath)
                        let dependencyCheckoutDir = workingDirectoryURL.appendingPathComponent(Constants.checkoutsPath, isDirectory: true)
                        return !dependencyCheckoutDir.hasSubdirectory(projectURL)
                    }
                    .flatMap(.concat) { settings -> SignalProducer<BuildSettings, CarthageError> in resolveSameTargetName(for: settings) }
                    .collect()
                    .flatMap(.concat) { (settings: [BuildSettings]) -> SignalProducer<TaskEvent<BuildSettings>, CarthageError> in
                        let actions: [String] = {
                            var result: [String] = [xcodebuildAction.rawValue]
                            if xcodebuildAction == .archive {
                                result += [
                                    // Prevent generating unnecessary empty `.xcarchive`
                                    // directories.
                                    "-archivePath", (NSTemporaryDirectory() as NSString).appendingPathComponent(workingDirectoryURL.lastPathComponent),

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
                                ]
                            }
                            result.append("SWIFT_COMPILATION_MODE=wholemodule")

                            return result
                        }()

                        let buildScheme = xcodebuildTask(actions, argsForBuilding, workingDirectoryPath: workingDirectoryURL.path)
                        return buildScheme.launch()
                            .flatMapTaskEvents(.concat) { _ in SignalProducer(settings) }
                            .mapError(CarthageError.taskError)
                    }
        }
    }

    /// Creates a dSYM for the provided dynamic framework.
    private static func createDebugInformation(_ builtProductURL: URL) -> SignalProducer<TaskEvent<URL>, CarthageError> {
        let dSYMURL = builtProductURL.appendingPathExtension("dSYM")

        let executableName = builtProductURL.deletingPathExtension().lastPathComponent
        if !executableName.isEmpty {
            let executable = builtProductURL.appendingPathComponent(executableName).path
            let dSYM = dSYMURL.path
            let dsymutilTask = Task("/usr/bin/xcrun", arguments: ["dsymutil", executable, "-o", dSYM])

            return dsymutilTask.launch()
                .mapError(CarthageError.taskError)
                .flatMapTaskEvents(.concat) { _ in SignalProducer(value: dSYMURL) }
        } else {
            return .empty
        }
    }

    /// Strips the given architecture from a framework.
    private static func stripArchitecture(_ frameworkURL: URL, _ architecture: String) -> SignalProducer<(), CarthageError> {
        return SignalProducer<URL, CarthageError> { () -> Result<URL, CarthageError> in Frameworks.binaryURL(frameworkURL) }
            .flatMap(.merge) { binaryURL -> SignalProducer<TaskEvent<Data>, CarthageError> in
                let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-remove", architecture, "-output", binaryURL.path, binaryURL.path])
                return lipoTask.launch()
                    .mapError(CarthageError.taskError)
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }

    /// Strips debug symbols from the given framework
    private static func stripDebugSymbols(_ frameworkURL: URL) -> SignalProducer<(), CarthageError> {
        return SignalProducer<URL, CarthageError> { () -> Result<URL, CarthageError> in Frameworks.binaryURL(frameworkURL) }
            .flatMap(.merge) { binaryURL -> SignalProducer<TaskEvent<Data>, CarthageError> in
                let stripTask = Task("/usr/bin/xcrun", arguments: [ "strip", "-S", "-o", binaryURL.path, binaryURL.path])
                return stripTask.launch()
                    .mapError(CarthageError.taskError)
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }

    /// Strips `Headers` directory from the given framework.
    private static func stripHeadersDirectory(_ frameworkURL: URL) -> SignalProducer<(), CarthageError> {
        return stripDirectory(named: "Headers", of: frameworkURL)
    }

    /// Strips `PrivateHeaders` directory from the given framework.
    private static func stripPrivateHeadersDirectory(_ frameworkURL: URL) -> SignalProducer<(), CarthageError> {
        return stripDirectory(named: "PrivateHeaders", of: frameworkURL)
    }

    /// Strips `Modules` directory from the given framework.
    private static func stripModulesDirectory(_ frameworkURL: URL) -> SignalProducer<(), CarthageError> {
        return stripDirectory(named: "Modules", of: frameworkURL)
    }

    private static func stripDirectory(named directory: String, of frameworkURL: URL) -> SignalProducer<(), CarthageError> {
        return SignalProducer { () -> Result<(), CarthageError> in
            let directoryURLToStrip = frameworkURL.appendingPathComponent(directory, isDirectory: true)

            return Result(at: directoryURLToStrip, attempt: {
                guard $0.isExistingDirectory else {
                    return
                }
                try FileManager.default.removeItem(at: $0)
            })
        }
    }

    /// Signs a framework with the given codesigning identity.
    private static func codesign(_ frameworkURL: URL, _ expandedIdentity: String) -> SignalProducer<(), CarthageError> {
        let codesignTask = Task(
            "/usr/bin/xcrun",
            arguments: ["codesign", "--force", "--sign", expandedIdentity, "--preserve-metadata=identifier,entitlements", frameworkURL.path]
        )
        return codesignTask.launch()
            .mapError(CarthageError.taskError)
            .then(SignalProducer<(), CarthageError>.empty)
    }
}

extension SignalProducer where Value: TaskEventType {
    /// Collect all TaskEvent success values and then send as a single array and complete.
    /// standard output and standard error data events are still sent as they are received.
    fileprivate func collectTaskEvents() -> SignalProducer<TaskEvent<[Value.T]>, Error> {
        return lift { $0.collectTaskEvents() }
    }
}

extension Signal where Value: TaskEventType {
    /// Collect all TaskEvent success values and then send as a single array and complete.
    /// standard output and standard error data events are still sent as they are received.
    fileprivate func collectTaskEvents() -> Signal<TaskEvent<[Value.T]>, Error> {
        var taskValues: [Value.T] = []

        return Signal<TaskEvent<[Value.T]>, Error> { observer, lifetime in
            lifetime += self.observe { event in
                switch event {
                case let .value(value):
                    if let taskValue = value.value {
                        taskValues.append(taskValue)
                    } else {
                        observer.send(value: value.map { [$0] })
                    }

                case .completed:
                    observer.send(value: .success(taskValues))
                    observer.sendCompleted()

                case let .failed(error):
                    observer.send(error: error)

                case .interrupted:
                    observer.sendInterrupted()
                }
            }
        }
    }
}
