import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD

public final class Archive {

    // MARK: - Public

    public static func archiveFrameworks(frameworkNames: [String], dependencyName: String?, directoryURL: URL, customOutputPath: String?, frameworkFoundHandler: ((String) -> Void)? = nil) -> SignalProducer<URL, CarthageError> {

        if let definedOutputPath = customOutputPath, definedOutputPath.isEmpty {
            return SignalProducer<URL, CarthageError>(error: CarthageError.invalidArgument(description: "Custom archive output path should not be empty"))
        }

        var effectiveDependencyName: String? = dependencyName
        let configuration = Xcode.defaultBuildConfiguration
        let frameworks: SignalProducer<[String], CarthageError>
        if !frameworkNames.isEmpty {
            frameworks = .init(value: frameworkNames.map {
                return $0.appendingPathExtension("framework")
            })
        } else {

            if effectiveDependencyName == nil {
                // try to infer the dependency name from the project at the specified directoryURL. It's not required, so we don't transmit any error.
                effectiveDependencyName = Dependencies.fetchDependencyNameForRepository(at: directoryURL).first()?.value
            }

            frameworks = Xcode.buildableSchemesInDirectory(directoryURL, withConfiguration: configuration)
                .flatMap(.merge) { scheme, project -> SignalProducer<BuildSettings, CarthageError> in
                    let buildArguments = BuildArguments(project: project, scheme: scheme, configuration: configuration)
                    return Xcode.loadBuildSettings(with: buildArguments)
                }
                .flatMap(.concat) { settings -> SignalProducer<String, CarthageError> in
                    if let wrapperName = settings.wrapperName.value, settings.productType.value == .framework {
                        return .init(value: wrapperName)
                    } else {
                        return .empty
                    }
                }
                .collect()
                .map { Array(Set($0)).sorted() }
        }

        return frameworks.flatMap(.merge) { frameworks -> SignalProducer<URL, CarthageError> in
            return SignalProducer<Platform, CarthageError>(Platform.supportedPlatforms)
                .flatMap(.merge) { platform -> SignalProducer<String, CarthageError> in
                    return SignalProducer(frameworks).map { framework in
                        return platform.relativePath.appendingPathComponent(framework)
                    }
                }
                .map { relativePath -> (relativePath: String, url: URL) in
                    return (relativePath, directoryURL.appendingPathComponent(relativePath))
                }
                .filter { file in file.url.isExistingFileOrDirectory }
                .flatMap(.merge) { framework -> SignalProducer<String, CarthageError> in
                    let dSYM = framework.relativePath.appendingPathExtension("dSYM")
                    let versionFilePath = effectiveDependencyName.map { VersionFile.versionFileRelativePath(dependencyName: $0) }
                    let bcsymbolmapsProducer = Frameworks.BCSymbolMapsForFramework(framework.url)
                        // generate relative paths for the bcsymbolmaps so they print nicely
                        .map { url in framework.relativePath.deletingLastPathComponent.appendingPathComponent(url.lastPathComponent) }
                    let extraFilesProducer = SignalProducer(value: dSYM)
                        .concat(bcsymbolmapsProducer)
                        .concat(versionFilePath.flatMap { path -> SignalProducer<String, CarthageError>? in
                            return directoryURL.appendingPathComponent(path).isExistingFile ? SignalProducer<String, CarthageError>(value: path) : nil } ?? SignalProducer<String, CarthageError>.empty)
                    return SignalProducer(value: framework.relativePath)
                        .concat(extraFilesProducer)
                }
                .on(value: { path in
                    frameworkFoundHandler?(path)
                })
                .collect()
                .flatMap(.merge) { paths -> SignalProducer<URL, CarthageError> in

                    let foundFrameworks = paths
                        .lazy
                        .map { $0.lastPathComponent }
                        .filter { $0.hasSuffix(".framework") }

                    if Set(foundFrameworks) != Set(frameworks) {
                        let error = CarthageError.invalidArgument(
                            description: "Could not find any copies of \(frameworks.joined(separator: ", ")). "
                                + "Make sure you're in the project's root and that the frameworks have already been built using 'carthage build --no-skip-current'."
                        )
                        return SignalProducer(error: error)
                    }

                    let outputPath = outputPathForBasePath(customOutputPath, frameworks: frameworks)
                    let outputURL = URL(fileURLWithPath: outputPath, isDirectory: false)

                    _ = try? FileManager
                        .default
                        .removeItem(at: outputURL)
                    _ = try? FileManager
                        .default
                        .createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                    return zip(paths: paths, into: outputURL, workingDirectoryURL: directoryURL)
            }
        }
    }

    // MARK: - Internal

    static func hasTarExtension(fileURL: URL) -> Bool {
        return ["gz", "tgz", "bz2", "xz"].contains(fileURL.pathExtension)
    }

    /// Unarchives the given file URL into a temporary directory, using its
    /// extension to detect archive type, then sends the file URL to that directory.
    static func unarchive(archive fileURL: URL) -> SignalProducer<URL, CarthageError> {
        if hasTarExtension(fileURL: fileURL) {
            return untar(archive: fileURL)
        } else {
            return unzip(archive: fileURL)
        }
    }

    /// Zips the given input paths (recursively) into an archive that will be
    /// located at the given URL.
    static func zip(paths: [String], into archiveURL: URL, workingDirectoryURL: URL) -> SignalProducer<URL, CarthageError> {
        precondition(!paths.isEmpty)
        precondition(archiveURL.isFileURL)

        let task = Task("/usr/bin/env", arguments: [ "zip", "-q", "-r", "--symlinks", archiveURL.path ] + paths, workingDirectoryPath: workingDirectoryURL.path)

        return task.launch()
            .mapError(CarthageError.taskError)
            .then(SignalProducer<URL, CarthageError>(value: archiveURL))
    }

    // MARK: - Private

    /// Returns an appropriate output file path for the resulting zip file using
    /// the given option and frameworks.
    private static func outputPathForBasePath(_ basePath: String?, frameworks: [String]) -> String {
        let defaultOutputPath = "\(frameworks.first!).zip"

        return basePath.map { path -> String in
            if path.hasSuffix("/") {
                // The given path should be a directory.
                return path + defaultOutputPath
            }

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue {
                // If the given path is an existing directory, output a zip file
                // into that directory.
                return path.appendingPathComponent(defaultOutputPath)
            } else {
                // Use the given path as the final output.
                return path
            }
            } ?? defaultOutputPath
    }

    /// Unzips the archive at the given file URL, extracting into the given
    /// directory URL (which must already exist).
    private static func unzip(archive fileURL: URL, to destinationDirectoryURL: URL) -> SignalProducer<URL, CarthageError> {
        precondition(fileURL.isFileURL)
        precondition(destinationDirectoryURL.isFileURL)

        let task = Task("/usr/bin/env", arguments: [ "unzip", "-uo", "-qq", "-d", destinationDirectoryURL.path, fileURL.path ])
        return task.launch()
            .mapError(CarthageError.taskError)
            .then(SignalProducer<URL, CarthageError>(value: destinationDirectoryURL))
    }

    /// Untars an archive at the given file URL, extracting into the given
    /// directory URL (which must already exist).
    private static func untar(archive fileURL: URL, to destinationDirectoryURL: URL) -> SignalProducer<URL, CarthageError> {
        precondition(fileURL.isFileURL)
        precondition(destinationDirectoryURL.isFileURL)

        let task = Task("/usr/bin/env", arguments: [ "tar", "-xf", fileURL.path, "-C", destinationDirectoryURL.path ])
        return task.launch()
            .mapError(CarthageError.taskError)
            .then(SignalProducer<URL, CarthageError>(value: destinationDirectoryURL))
    }

    /// Unzips the archive at the given file URL into a temporary directory, then
    /// sends the file URL to that directory.
    private static func unzip(archive fileURL: URL) -> SignalProducer<URL, CarthageError> {
        return FileManager.default.reactive.createTemporaryDirectory()
            .flatMap(.merge) { directoryURL in
                return unzip(archive: fileURL, to: directoryURL)
                    .then(SignalProducer<URL, CarthageError>(value: directoryURL))
        }
    }

    /// Untars an archive at the given file URL into a temporary directory,
    /// then sends the file URL to that directory.
    private static func untar(archive fileURL: URL) -> SignalProducer<URL, CarthageError> {
        return FileManager.default.reactive.createTemporaryDirectory()
            .flatMap(.merge) { directoryURL in
                return untar(archive: fileURL, to: directoryURL)
                    .then(SignalProducer<URL, CarthageError>(value: directoryURL))
        }
    }
}
