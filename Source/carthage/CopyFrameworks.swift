import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveSwift
import Curry

/// Type that encapsulates the configuration and evaluation of the `copy-frameworks` subcommand.
public struct CopyFrameworksCommand: CommandProtocol {
    public struct Options: OptionsProtocol {
        public let automatic: Bool
        public let useFrameworkSearchPaths: Bool
        public let isVerbose: Bool
        
        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            return curry(self.init)
                <*> mode <| Option(key: "auto", defaultValue: false, usage: "infers and copies linked frameworks automatically")
                <*> mode <| Option(key: "use-framework-search-paths", defaultValue: false, usage: "uses FRAMEWORK_SEARCH_PATHS environment variable to copy the linked frameworks with paths order preservation (i.e. first occurrence wins).\nTakes effect only when `--auto` argument is being passed")
                <*> mode <| Option(key: "verbose", defaultValue: false, usage: "print automatically copied frameworks and paths")
        }
    }
    
    public let verb = "copy-frameworks"
    public let function = "In a Run Script build phase, copies each framework specified by a SCRIPT_INPUT_FILE and/or SCRIPT_INPUT_FILE_LIST environment variables into the built app bundle"

    public func run(_ options: Options) -> Result<(), CarthageError> {
        do {
            let frameworksFolder: URL = try self.frameworksFolder().get()
            let validArchitectures: [String] = try self.validArchitectures().get()
            let codeSigningIdentity: String? = try self.codeSigningIdentity().get()
            let shouldStripDebugSymbols: Bool = self.shouldStripDebugSymbols()
            let shouldCopyBCSymbolMap: Bool = self.buildActionIsArchiveOrInstall()
            let symbolsFolder: URL = try self.appropriateDestinationFolder().get()

            let waitHandler: (URL) -> Void = { url in
                carthage.println("Waiting for lock on url: \(url)")
            }
            
            // We don't want to copy outdated frameworks. i.e. such frameworks that are being modified
            // earlier that existing products at the `target` URL.
            // This typically indicates that we're copying a wrong framework. This may
            // be result of the `options.useFrameworkSearchPaths == true` when Carthage will try
            // to copy all of the linked frameworks that are available at the FRAMEWORK_SEARCH_PATHS,
            // while those frameworks already copied by 'Embed Frameworks' phase for example.
            // Also we don't want to force new behaviour of skipping outdated and enabling it only
            // for automatic option.
            let skipIfOutdated = options.automatic

            return inputFiles(options)
                .flatMap(.merge) { frameworkURL -> SignalProducer<FrameworkEvent, CarthageError> in
                    return CopyFramework.copyFramework(frameworkURL: frameworkURL, frameworksFolder: frameworksFolder, symbolsFolder: symbolsFolder, validArchitectures: validArchitectures, codeSigningIdentity: codeSigningIdentity, shouldStripDebugSymbols: shouldStripDebugSymbols, shouldCopyBCSymbolMap: shouldCopyBCSymbolMap, skipIfOutdated: skipIfOutdated, waitHandler: waitHandler)
                        // Copy as many frameworks as possible in parallel.
                        .start(on: QueueScheduler(name: "org.carthage.CarthageKit.CopyFrameworks.copy"))
                }
                .on(value: { (event) in
                    switch event {
                    case .copied(let frameworkName):
                        carthage.println("Copied \(frameworkName)")
                    case .ignored(let frameworkName):
                        carthage.println("warning: Ignoring \(frameworkName) because it does not support the current architecture\n")
                    }
                })
                .waitOnCommand()
        } catch let carthageError as CarthageError {
            return .failure(carthageError)
        } catch {
            return .failure(.internalError(description: error.localizedDescription))
        }
    }
    
    private func codeSigningIdentity() -> Result<String?, CarthageError> {
        return Result<Bool, CarthageError>(codeSigningAllowed())
            .flatMap { (codeSigningAllowed: Bool) -> Result<String?, CarthageError> in
                guard codeSigningAllowed == true else { return .success(nil) }
                
                return Environment.getVariable("EXPANDED_CODE_SIGN_IDENTITY")
                    .map { $0.isEmpty ? nil : $0 }
                    .flatMapError {
                        // See https://github.com/Carthage/Carthage/issues/2472#issuecomment-395134166 regarding Xcode 10 betas
                        // … or potentially non-beta Xcode releases of major version 10 or later.
                        
                        switch Environment.getVariable("XCODE_PRODUCT_BUILD_VERSION") {
                        case .success:
                            // See the above issue.
                            return .success(nil)
                        case .failure:
                            // For users calling `carthage copy-frameworks` outside of Xcode (admittedly,
                            // a small fraction), this error is worthwhile in being a signpost in what’s
                            // necessary to add to achieve (for what most is the goal) of ensuring
                            // that code signing happens.
                            return .failure($0)
                        }
                }
        }
    }
    
    private func codeSigningAllowed() -> Bool {
        return Environment.getVariable("CODE_SIGNING_ALLOWED")
            .map { $0 == "YES" }.value ?? false
    }
    
    private func shouldStripDebugSymbols() -> Bool {
        return Environment.getVariable("COPY_PHASE_STRIP")
            .map { $0 == "YES" }.value ?? false
    }
    
    // The fix for https://github.com/Carthage/Carthage/issues/1259
    private func appropriateDestinationFolder() -> Result<URL, CarthageError> {
        if buildActionIsArchiveOrInstall() {
            return builtProductsFolder()
        } else {
            return targetBuildFolder()
        }
    }
    
    private func builtProductsFolder() -> Result<URL, CarthageError> {
        return Environment.getVariable("BUILT_PRODUCTS_DIR")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    
    private func targetBuildFolder() -> Result<URL, CarthageError> {
        return Environment.getVariable("TARGET_BUILD_DIR")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    
    private func executablePath() -> Result<URL, CarthageError> {
        return appropriateDestinationFolder().flatMap { url in
            return Environment.getVariable("EXECUTABLE_PATH").map { path in
                return url.appendingPathComponent(path)
            }
        }
    }
    
    private func frameworksFolder() -> Result<URL, CarthageError> {
        return appropriateDestinationFolder()
            .flatMap { url -> Result<URL, CarthageError> in
                Environment.getVariable("FRAMEWORKS_FOLDER_PATH")
                    .map { url.appendingPathComponent($0, isDirectory: true) }
        }
    }
    
    private func frameworkSearchPaths() -> Result<[URL], CarthageError> {
        return appropriateDestinationFolder().flatMap { url in
            return Environment.getVariable("FRAMEWORK_SEARCH_PATHS").map { rawFrameworkSearchPaths -> [URL] in
                return InputFilesInferrer.frameworkSearchPaths(from: rawFrameworkSearchPaths)
            }
        }
    }
    
    private func projectDirectory() -> Result<URL, CarthageError> {
        return Environment.getVariable("PROJECT_FILE_PATH")
            .map { URL(fileURLWithPath: $0, isDirectory: false).deletingLastPathComponent() }
    }
    
    private func validArchitectures() -> Result<[String], CarthageError> {
        return Environment.getVariable("VALID_ARCHS").map { architectures -> [String] in
            return architectures.components(separatedBy: " ")
        }
    }
    
    private func buildActionIsArchiveOrInstall() -> Bool {
        // archives use ACTION=install
        return Environment.getVariable("ACTION").value == "install"
    }
    
    private func inputFiles(_ options: CopyFrameworksCommand.Options) -> SignalProducer<URL, CarthageError> {
        var inputFiles = SignalProducer(values: scriptInputFiles(), scriptInputFileLists())
            .flatten(.merge)
            .uniqueValues()
        
        if options.automatic {
            inputFiles = inputFiles.concat(
                inferredInputFiles(using: inputFiles, useFrameworkSearchPaths: options.useFrameworkSearchPaths)
                    .on(
                        starting: {
                            if options.isVerbose {
                                carthage.println("Going to copy automatically:\n")
                            }
                    },
                        value: { path in
                            if options.isVerbose {
                                let name = URL(fileURLWithPath: path).lastPathComponent
                                carthage.println("\"\(name)\" at: \"\(path)\"")
                            }
                    }
                )
            )
        }
        
        return inputFiles.map { URL(fileURLWithPath: $0) }
    }
    
    private func scriptInputFiles() -> SignalProducer<String, CarthageError> {
        switch Environment.getVariable("SCRIPT_INPUT_FILE_COUNT") {
        case .success(let count):
            if let count = Int(count) {
                return SignalProducer<Int, CarthageError>(0..<count).attemptMap { Environment.getVariable("SCRIPT_INPUT_FILE_\($0)") }
            } else {
                return SignalProducer(error: .invalidArgument(description: "SCRIPT_INPUT_FILE_COUNT did not specify a number"))
            }
        case .failure:
            return .empty
        }
    }
    
    private func scriptInputFileLists() -> SignalProducer<String, CarthageError> {
        switch Environment.getVariable("SCRIPT_INPUT_FILE_LIST_COUNT") {
        case .success(let count):
            if let count = Int(count) {
                return SignalProducer<Int, CarthageError>(0..<count)
                    .attemptMap { Environment.getVariable("SCRIPT_INPUT_FILE_LIST_\($0)") }
                    .flatMap(.merge) { fileList -> SignalProducer<String, CarthageError> in
                        let fileListURL = URL(fileURLWithPath: fileList, isDirectory: true)
                        return SignalProducer<String, NSError>(result: Result(catching: { try String(contentsOfFile: fileList) }))
                            .mapError { CarthageError.readFailed(fileListURL, $0) }
                    }
                    .map { $0.split(separator: "\n").map(String.init) }
                    .flatMap(.merge) { SignalProducer($0) }
            } else {
                return SignalProducer(error: .invalidArgument(description: "SCRIPT_INPUT_FILE_LIST_COUNT did not specify a number"))
            }
        case .failure:
            return .empty
        }
    }
    
    private func inferredInputFiles(
        using userInputFiles: SignalProducer<String, CarthageError>,
        useFrameworkSearchPaths: Bool
        ) -> SignalProducer<String, CarthageError> {
        if
            let directory = projectDirectory().value,
            let platformName = Environment.getVariable("PLATFORM_NAME").value,
            let platform = BuildPlatform.from(string: platformName)?.platforms.first,
            let executable = executablePath().value
        {
            let searchPaths = useFrameworkSearchPaths ? frameworkSearchPaths() : nil
            if case .failure(let error)? = searchPaths {
                return SignalProducer(error: error)
            }
            
            return InputFilesInferrer(projectDirectory: directory, platform: platform, frameworkSearchPaths: searchPaths?.value ?? [])
                .inputFiles(for: executable, userInputFiles: userInputFiles.map(URL.init(fileURLWithPath:)))
                .map { $0.path }
        }
        
        return .empty
    }

}
