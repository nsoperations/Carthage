import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD
import Curry

extension BuildOptions: OptionsProtocol {
    public static func evaluate(_ mode: CommandMode) -> Result<BuildOptions, CommandantError<CarthageError>> {
        return evaluate(mode, addendum: "")
    }

    public static func evaluate(_ mode: CommandMode, addendum: String) -> Result<BuildOptions, CommandantError<CarthageError>> {
        var platformUsage = "the platforms to build for (one of 'all', 'macOS', 'iOS', 'watchOS', 'tvOS', or comma-separated values of the formers except for 'all')"
        platformUsage += addendum

        let option1 = Option(key: "configuration", defaultValue: "Release", usage: "the Xcode configuration to build" + addendum)
        let option2 = Option<String?>(key: "toolchain", defaultValue: nil, usage: "the toolchain to build with")
        let option3 = Option<String?>(key: "derived-data", defaultValue: nil, usage: "path to the custom derived data folder")
        let option4 = Option(key: "cache-builds", defaultValue: false, usage: "use cached builds when possible")
        let option5 = Option(key: "use-binaries", defaultValue: true, usage: "don't use remotely or locally cached binaries when possible")
        let option6 = Option<String?>(key: "cache-command", defaultValue: Environment.getVariable("CARTHAGE_CACHE_COMMAND").value, usage: "custom command to execute to download cached (binary) dependencies from a custom cache store. Five environment variables will be set which can be used by the command if needed: [CARTHAGE_CACHE_DEPENDENCY_NAME, CARTHAGE_CACHE_DEPENDENCY_VERSION, CARTHAGE_CACHE_BUILD_CONFIGURATION, CARTHAGE_CACHE_SWIFT_VERSION, CARTHAGE_CACHE_TARGET_FILE_PATH]. The executable should move the cached file to the targetFilePath when successful. The CARTHAGE_CACHE_COMMAND environment variable is read for a default for this value. If not specified, caching will revert to caching based on the GitHub API which only works for GitHub dependencies.")
        let option7 = Option(key: "track-local-changes", defaultValue: false, usage: "track local changes made to dependencies to determine if a rebuild is necessary in combination with --use-binaries/--cache-builds. By default only the git commit hash is used so a rebuild is triggered only if the dependency commit hash did change.")

        return curry(self.init)
            <*> mode <| option1
            <*> (mode <| Option<BuildPlatform>(key: "platform", defaultValue: .all, usage: platformUsage)).map { $0.platforms }
            <*> mode <| option2
            <*> mode <| option3
            <*> mode <| option4
            <*> mode <| option5
            <*> mode <| option6
            <*> mode <| option7
            <*> mode <| SharedOptions.netrcOption
    }
}

/// Type that encapsulates the configuration and evaluation of the `build` subcommand.
public struct BuildCommand: CommandProtocol {
    public struct Options: OptionsProtocol {
        public let buildOptions: BuildOptions
        public let skipCurrent: Bool
        public let colorOptions: ColorOptions
        public let isVerbose: Bool
        public let directoryPath: String
        public let logPath: String?
        public let archive: Bool
        public let archiveOutputPath: String?
        public let lockTimeout: Int?
        public let dependenciesToBuild: [String]?

        /// If `archive` is true, this will be a producer that will archive
        /// the project after the build.
        ///
        /// Otherwise, this producer will be empty.
        public var archiveProducer: SignalProducer<URL, CarthageError> {
            if archive {
                let options = ArchiveCommand.Options(outputPath: archiveOutputPath, directoryPath: directoryPath, colorOptions: colorOptions, frameworkNames: [])
                return ArchiveCommand().archiveWithOptions(options)
            } else {
                return .empty
            }
        }

        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {

            let option1 = Option(key: "skip-current", defaultValue: true, usage: "don't skip building the Carthage project (in addition to its dependencies)")
            let option2 = Option(key: "verbose", defaultValue: false, usage: "print xcodebuild output inline")
            let option3 = Option(key: "project-directory", defaultValue: FileManager.default.currentDirectoryPath, usage: "the directory containing the Carthage project")
            let option4 = Option<String?>(key: "log-path", defaultValue: nil, usage: "path to the xcode build output. A temporary file is used by default")
            let option5 = Option(key: "archive", defaultValue: false, usage: "archive built frameworks from the current project (implies --no-skip-current)")
            let option6 = Option<String?>(
                key: "archive-output",
                defaultValue: nil,
                usage: "the path at which to create the archive zip file (or blank to infer it from the first one of the framework names)"
            )
            let option7 = Option<Int?>(key: "lock-timeout", defaultValue: nil, usage: "timeout in seconds to wait for an exclusive lock on shared files, defaults to no timeout")

            return curry(self.init)
                <*> BuildOptions.evaluate(mode)
                <*> mode <| option1
                <*> ColorOptions.evaluate(mode)
                <*> mode <| option2
                <*> mode <| option3
                <*> mode <| option4
                <*> mode <| option5
                <*> mode <| option6
                <*> mode <| option7
                <*> (mode <| Argument(defaultValue: [], usage: "the dependency names to build", usageParameter: "dependency names")).map { $0.isEmpty ? nil : $0 }
        }
    }

    public let verb = "build"
    public let function = "Build the project's dependencies"

    public func run(_ options: Options) -> Result<(), CarthageError> {
        return self.buildWithOptions(options)
            .then(options.archiveProducer)
            .waitOnCommand()
    }

    /// Builds a project with the given options.
    public func buildWithOptions(_ options: Options) -> SignalProducer<(), CarthageError> {
        let directoryURL = URL(fileURLWithPath: options.directoryPath, isDirectory: true)
        let project = Project(directoryURL: directoryURL, useNetrc: options.buildOptions.useNetrc)
        let eventSink = ProjectEventLogger(colorOptions: options.colorOptions)
        project.projectEvents.observeValues { eventSink.log(event: $0) }
        
        return self.build(project: project, options: options)
    }

    public func build(project: Project, options: Options) -> SignalProducer<(), CarthageError> {
        return self.openLoggingHandle(options)
            .flatMap(.merge) { stdoutHandle, temporaryURL -> SignalProducer<(), CarthageError> in

                let shouldBuildCurrentProject =  !options.skipCurrent || options.archive

                project.lockTimeout = options.lockTimeout
                let buildProgress = project.build(includingSelf: shouldBuildCurrentProject, dependenciesToBuild: options.dependenciesToBuild, buildOptions: options.buildOptions)

                let stderrHandle = options.isVerbose ? FileHandle.standardError : stdoutHandle

                let formatting = options.colorOptions.formatting

                return buildProgress
                    .mapError { error -> CarthageError in
                        if case let .buildFailed(taskError, _) = error {
                            return .buildFailed(taskError, log: temporaryURL)
                        } else {
                            return error
                        }
                    }
                    .on(
                        started: {
                            if let path = temporaryURL?.path {
                                carthage.println(formatting.bullets + "xcodebuild output can be found in " + formatting.path(path))
                            }
                    },
                        value: { taskEvent in
                            switch taskEvent {
                            case let .launch(task):
                                stdoutHandle.write(task.description.data(using: .utf8)!)

                            case let .standardOutput(data):
                                stdoutHandle.write(data)

                            case let .standardError(data):
                                stderrHandle.write(data)

                            case let .success(project, scheme):
                                carthage.println(formatting.bullets + "Building scheme " + formatting.quote(scheme.name) + " in " + formatting.projectName(project.description))
                            }
                    }
                    )
                    .then(SignalProducer<(), CarthageError>.empty)
        }
    }

    /// Opens an existing file, if provided, or creates a temporary file if not, returning a handle and the URL to the
    /// file.
    private func openLogFile(_ path: String?) -> SignalProducer<(FileHandle, URL), CarthageError> {
        return SignalProducer { () -> Result<(FileHandle, URL), CarthageError> in
            if let path = path {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
                let fileURL = URL(fileURLWithPath: path, isDirectory: false)

                guard let handle = FileHandle(forUpdatingAtPath: path) else {
                    let error = NSError(domain: Constants.bundleIdentifier,
                                        code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Unable to open file handle for file at \(path)"])
                    return .failure(.writeFailed(fileURL, error))
                }

                return .success((handle, fileURL))
            } else {
                var temporaryDirectoryTemplate: ContiguousArray<CChar>
                temporaryDirectoryTemplate = (NSTemporaryDirectory() as NSString).appendingPathComponent("carthage-xcodebuild.XXXXXX.log").utf8CString
                let logFD = temporaryDirectoryTemplate.withUnsafeMutableBufferPointer { (template: inout UnsafeMutableBufferPointer<CChar>) -> Int32 in
                    return mkstemps(template.baseAddress, 4)
                }
                let logPath = temporaryDirectoryTemplate.withUnsafeBufferPointer { (ptr: UnsafeBufferPointer<CChar>) -> String in
                    return String(validatingUTF8: ptr.baseAddress!)!
                }
                if logFD < 0 {
                    return .failure(.writeFailed(URL(fileURLWithPath: logPath, isDirectory: false), NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)))
                }

                let handle = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
                let fileURL = URL(fileURLWithPath: logPath, isDirectory: false)

                return .success((handle, fileURL))
            }
        }
    }

    /// Opens a file handle for logging, returning the handle and the URL to any
    /// temporary file on disk.
    private func openLoggingHandle(_ options: Options) -> SignalProducer<(FileHandle, URL?), CarthageError> {
        if options.isVerbose {
            let out: (FileHandle, URL?) = (FileHandle.standardOutput, nil)
            return SignalProducer(value: out)
        } else {
            return openLogFile(options.logPath)
                .map { handle, url in (handle, Optional(url)) }
        }
    }
}

/// Represents the user's chosen platform to build for.
public enum BuildPlatform: Equatable {
    /// Build for all available platforms.
    case all

    /// Build only for iOS.
    case iOS

    /// Build only for macOS.
    case macOS

    /// Build only for watchOS.
    case watchOS

    /// Build only for tvOS.
    case tvOS

    /// Build for multiple platforms within the list.
    case multiple([BuildPlatform])

    /// The set of `Platform` corresponding to this setting.
    public var platforms: Set<Platform> {
        switch self {
        case .all:
            return []

        case .iOS:
            return [ .iOS ]

        case .macOS:
            return [ .macOS ]

        case .watchOS:
            return [ .watchOS ]

        case .tvOS:
            return [ .tvOS ]

        case let .multiple(buildPlatforms):
            return buildPlatforms.reduce(into: []) { set, buildPlatform in
                set.formUnion(buildPlatform.platforms)
            }
        }
    }
}

extension BuildPlatform: CustomStringConvertible {
    public var description: String {
        switch self {
        case .all:
            return "all"

        case .iOS:
            return "iOS"

        case .macOS:
            return "macOS"

        case .watchOS:
            return "watchOS"

        case .tvOS:
            return "tvOS"

        case let .multiple(buildPlatforms):
            return buildPlatforms.map { $0.description }.joined(separator: ", ")
        }
    }
}

extension BuildPlatform: ArgumentProtocol {
    public static let name = "platform"

    private static let acceptedStrings: [String: BuildPlatform] = [
        "macOS": .macOS, "Mac": .macOS, "OSX": .macOS, "macosx": .macOS,
        "iOS": .iOS, "iphoneos": .iOS, "iphonesimulator": .iOS,
        "watchOS": .watchOS, "watchsimulator": .watchOS,
        "tvOS": .tvOS, "tvsimulator": .tvOS, "appletvos": .tvOS, "appletvsimulator": .tvOS,
        "all": .all,
    ]

    public static func from(string: String) -> BuildPlatform? {
        let tokens = string.split()

        let findBuildPlatform: (String) -> BuildPlatform? = { string in
            return self.acceptedStrings
                .first { key, _ in string.caseInsensitiveCompare(key) == .orderedSame }
                .map { _, platform in platform }
        }

        switch tokens.count {
        case 0:
            return nil

        case 1:
            return findBuildPlatform(tokens[0])

        default:
            var buildPlatforms = [BuildPlatform]()
            for token in tokens {
                if let found = findBuildPlatform(token), found != .all {
                    buildPlatforms.append(found)
                } else {
                    // Reject if an invalid value is included in the comma-
                    // separated string.
                    return nil
                }
            }
            return .multiple(buildPlatforms)
        }
    }
}
