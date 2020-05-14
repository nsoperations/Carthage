import Foundation
import Result
import ReactiveSwift
import XCDBLD
import ReactiveTask

/// Describes the type of frameworks.
enum FrameworkType {
    /// A dynamic framework.
    case dynamic

    /// A static framework.
    case `static`

    init?(productType: ProductType, machOType: MachOType) {
        switch (productType, machOType) {
        case (.framework, .dylib):
            self = .dynamic

        case (.framework, .staticlib):
            self = .static

        case _:
            return nil
        }
    }

    /// Folder name for static framework's subdirectory
    static let staticFolderName = "Static"
}

/// Describes the type of packages, given their CFBundlePackageType.
enum PackageType: String {
    /// A .framework package.
    case framework = "FMWK"

    /// A .bundle package. Some frameworks might have this package type code
    /// (e.g. https://github.com/ResearchKit/ResearchKit/blob/1.3.0/ResearchKit/Info.plist#L15-L16).
    case bundle = "BNDL"

    /// A .dSYM package.
    case dSYM = "dSYM"
}

/// Describes an event occurring to or with a framework.
public enum FrameworkEvent {
    case ignored(String)
    case skipped(String)
    case copied(String)
}

public struct PlatformFramework: Hashable {
    let name: String
    let platform: Platform
}

final class Frameworks {
    /// Determines the Swift version of a framework at a given `URL`.
    static func frameworkSwiftVersionIfIsSwiftFramework(_ frameworkURL: URL) -> SignalProducer<PinnedVersion?, SwiftVersionError> {
        guard isSwiftFramework(frameworkURL) else {
            return SignalProducer(value: nil)
        }
        return frameworkSwiftVersion(frameworkURL).map(Optional.some)
    }

    /// Determines the Swift version of a framework at a given `URL`.
    static func frameworkSwiftVersion(_ frameworkURL: URL) -> SignalProducer<PinnedVersion, SwiftVersionError> {
        let candidateSwiftHeaderURLs = frameworkURL.candidateSwiftHeaderURLs()

        for swiftHeaderURL in candidateSwiftHeaderURLs {
            if let data = try? Data(contentsOf: swiftHeaderURL),
                let contents = String(data: data, encoding: .utf8),
                let swiftVersion = SwiftToolchain.swiftVersion(from: contents) {
                return SignalProducer(value: swiftVersion)
            }
        }
        return SignalProducer(error: .unknownFrameworkSwiftVersion(message: "Could not derive version from header file."))
    }

    static func dSYMSwiftVersion(_ dSYMURL: URL) -> SignalProducer<PinnedVersion, SwiftVersionError> {

        // Pick one architecture
        guard let arch = architecturesInPackage(dSYMURL).first()?.value else {
            return SignalProducer(error: .unknownFrameworkSwiftVersion(message: "No architectures found in dSYM."))
        }

        // Check the .debug_info section left from the compiler in the dSYM.
        let task = Task("/usr/bin/xcrun", arguments: ["dwarfdump", "--arch=\(arch)", "--debug-info", dSYMURL.path])

        //    $ dwarfdump --debug-info Carthage/Build/iOS/Swiftz.framework.dSYM
        //        ----------------------------------------------------------------------
        //    File: Carthage/Build/iOS/Swiftz.framework.dSYM/Contents/Resources/DWARF/Swiftz (i386)
        //    ----------------------------------------------------------------------
        //    .debug_info contents:
        //
        //    0x00000000: Compile Unit: length = 0x000000ac  version = 0x0004  abbr_offset = 0x00000000  addr_size = 0x04  (next CU at 0x000000b0)
        //
        //    0x0000000b: TAG_compile_unit [1] *
        //    AT_producer( "Apple Swift version 4.1.2 effective-3.3.2 (swiftlang-902.0.54 clang-902.0.39.2) -emit-object /Users/Tommaso/<redacted>

        let versions: [PinnedVersion]?  = task.launch(standardInput: nil)
            .ignoreTaskData()
            .mapError(CarthageError.taskError)
            .map { String(data: $0, encoding: .utf8) ?? "" }
            .filter { !$0.isEmpty }
            .flatMap(.merge) { (output: String) -> SignalProducer<String, NoError> in
                output.linesProducer
            }
            .filter { $0.contains("AT_producer") }
            .uniqueValues()
            .map { SwiftToolchain.swiftVersion(from: .some($0)) }
            .skipNil()
            .uniqueValues()
            .collect()
            .single()?
            .value

        let numberOfVersions = versions?.count ?? 0
        guard numberOfVersions != 0 else {
            return SignalProducer(error: .unknownFrameworkSwiftVersion(message: "No version found in dSYM."))
        }

        guard numberOfVersions == 1 else {
            let versionsString = versions!.map { $0.description }.joined(separator: " ")
            return SignalProducer(error: .unknownFrameworkSwiftVersion(message: "More than one found in dSYM - \(versionsString) ."))
        }

        return SignalProducer<PinnedVersion, SwiftVersionError>(value: versions!.first!)
    }

    /// Determines whether a framework was built with Swift
    static func isSwiftFramework(_ frameworkURL: URL) -> Bool {
        return frameworkURL.swiftmoduleURL() != nil
    }

    /// Sends a set of UUIDs for each architecture present in the given framework.
    static func UUIDsForFramework(_ frameworkURL: URL) -> SignalProducer<Set<UUID>, CarthageError> {
        return SignalProducer { () -> Result<URL, CarthageError> in binaryURL(frameworkURL) }
            .flatMap(.merge, UUIDsFromDwarfdump)
    }

    /// Sends a set of UUIDs for each architecture present in the given dSYM.
    static func UUIDsForDSYM(_ dSYMURL: URL) -> SignalProducer<Set<UUID>, CarthageError> {
        return UUIDsFromDwarfdump(dSYMURL)
    }

    /// Sends an URL for each bcsymbolmap file for the given framework.
    /// The files do not necessarily exist on disk.
    ///
    /// The returned URLs are relative to the parent directory of the framework.
    static func BCSymbolMapsForFramework(_ frameworkURL: URL) -> SignalProducer<URL, CarthageError> {
        let directoryURL = frameworkURL.deletingLastPathComponent()
        return UUIDsForFramework(frameworkURL)
            .flatMap(.merge) { uuids in SignalProducer<UUID, CarthageError>(uuids) }
            .map { uuid in
                return directoryURL.appendingPathComponent(uuid.uuidString, isDirectory: false).appendingPathExtension("bcsymbolmap")
        }
    }

    /// Returns the URL of a binary inside a given package.
    static func binaryURL(_ packageURL: URL) -> Result<URL, CarthageError> {
        let bundle = Bundle(path: packageURL.path)

        if let executableURL = bundle?.executableURL {
            return .success(executableURL)
        }

        if bundle?.packageType == .dSYM {
            let binaryName = packageURL.deletingPathExtension().deletingPathExtension().lastPathComponent
            if !binaryName.isEmpty {
                let binaryURL = packageURL.appendingPathComponent("Contents/Resources/DWARF/\(binaryName)")
                return .success(binaryURL)
            }
        }

        return .failure(.readFailed(packageURL, nil))
    }
    
    static func frameworksInBuildFolder(directoryURL: URL, platforms: Set<Platform>?) -> SignalProducer<(Platform, URL), CarthageError> {
        return SignalProducer<[(Platform, URL)], CarthageError> { () -> Result<[(Platform, URL)], CarthageError> in
            return CarthageResult.catching {
                let binariesURL = directoryURL.appendingPathComponent(Constants.binariesFolderPath)
                guard binariesURL.isExistingDirectory else {
                    return []
                }
                
                let subDirectoryURLs = try readURL(binariesURL) { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) }
                var allFrameworks = [(Platform, URL)]()
                
                for subDirectoryURL in subDirectoryURLs {
                    let isDirectory = try readURL(subDirectoryURL) {  try $0.resourceValues(forKeys: Set([.isDirectoryKey])).isDirectory ?? false }
                    if isDirectory,
                        let platform = Platform(rawValue: subDirectoryURL.lastPathComponent),
                        platforms?.contains(platform) ?? true {
                        try frameworksInDirectory(subDirectoryURL).collect().getOnly().forEach { url in
                            allFrameworks.append((platform, url))
                        }
                    }
                    
                }
                return allFrameworks
            }
        }.flatten()
    }
    
    static func hashForResolvedDependencySet(_ set: Set<PinnedDependency>) -> String {
        let digest = set.sorted().reduce(into: MD5Digest()) { digest, pinnedDependency in
            let string = "\(pinnedDependency.dependency.urlString)==\(pinnedDependency.pinnedVersion)"
            digest.update(data: string.data(using: .utf8)!)
        }
        let result = digest.finalize().hexString
        return result
    }
    
    static func definedSymbolsInBuildFolder(directoryURL: URL, platforms: Set<Platform>?) -> SignalProducer<(PlatformFramework, Set<String>), CarthageError> {
        return Frameworks.frameworksInBuildFolder(directoryURL: directoryURL, platforms: platforms)
            .flatMap(.concurrent(limit: Constants.concurrencyLimit)) { platformURL -> SignalProducer<(PlatformFramework, Set<String>), CarthageError> in
                let (platform, url) = platformURL
                return self.definedSymbols(frameworkURL: url)
                    .map { name, set in
                        return (PlatformFramework(name: name, platform: platform), set)
                    }
                    .startOnQueue(globalConcurrentProducerQueue)
            }
    }
    
    /// Sends the URL to each framework bundle found in the given directory.
    static func frameworksInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        return filesInDirectory(directoryURL, kUTTypeFramework as String)
            .filter { !$0.pathComponents.contains("__MACOSX") }
            .filter { url in
                let frameworkExtension = "framework"
                // Skip nested frameworks
                let frameworksInURL = url.pathComponents.filter { pathComponent in
                    return (pathComponent as NSString).pathExtension == frameworkExtension
                }
                return frameworksInURL.count == 1 && url.pathExtension == frameworkExtension
            }.filter { url in
                // For reasons of speed and the fact that CLI-output structures can change,
                // first try the safer method of reading the ‘Info.plist’ from the Framework’s bundle.
                let bundle = Bundle(url: url)
                let packageType: PackageType? = bundle?.packageType

                switch packageType {
                case .framework?, .bundle?:
                    return true
                default:
                    // In case no Info.plist exists check the Mach-O fileType
                    guard let executableURL = bundle?.executableURL else {
                        return false
                    }

                    return MachHeader.headers(forMachOFileAtUrl: executableURL)
                        .filter { MachHeader.carthageSupportedFileTypes.contains($0.fileType) }
                        .reduce(into: Set<UInt32>()) { $0.insert($1.fileType); return }
                        .map { $0.count == 1 }
                        .single()?
                        .value ?? false
                }
        }
    }

    static func bundlesInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        return filesInDirectory(directoryURL, kUTTypeBundle as String)
            .filter { !$0.pathComponents.contains("__MACOSX") }
            .filter { url in
                let bundleExtension = "bundle"
                // Skip nested bundles
                let bundlesInURL = url.pathComponents.filter { pathComponent in
                    return (pathComponent as NSString).pathExtension == bundleExtension
                }
                return bundlesInURL.count == 1 && url.pathExtension == bundleExtension
            }
    }

    static func platformForBundle(_ bundleURL: URL, relativeTo baseURL: URL) -> Platform? {
        guard let pathComponents = bundleURL.pathComponentsRelativeTo(baseURL) else {
            return nil
        }
        for component in pathComponents.reversed() {
            if let platform = Platform(rawValue: component) {
                return platform
            }
        }
        return nil
    }

    /// Sends the platform specified in the given Info.plist.
    static func platformForFramework(_ frameworkURL: URL) -> SignalProducer<Platform, CarthageError> {
        return SignalProducer(value: frameworkURL)
            // Neither DTPlatformName nor CFBundleSupportedPlatforms can not be used
            // because Xcode 6 and below do not include either in macOS frameworks.
            .attemptMap { url -> Result<String, CarthageError> in
                let bundle = Bundle(url: url)

                func readFailed(_ message: String) -> CarthageError {
                    let error = Result<(), NSError>.error(message)
                    return .readFailed(frameworkURL, error)
                }

                func sdkNameFromExecutable() -> String? {
                    guard let executableURL = bundle?.executableURL else {
                        return nil
                    }

                    let task = Task("/usr/bin/xcrun", arguments: ["otool", "-lv", executableURL.path])

                    let sdkName: String? = task.launch(standardInput: nil)
                        .ignoreTaskData()
                        .mapError(CarthageError.taskError)
                        .map { String(data: $0, encoding: .utf8) ?? "" }
                        .filter { !$0.isEmpty }
                        .flatMap(.merge) { (output: String) -> SignalProducer<String, NoError> in
                            output.linesProducer
                        }
                        .filter { $0.contains("LC_VERSION") }
                        .take(last: 1)
                        .map { lcVersionLine -> String? in
                            let sdkString = lcVersionLine.split(separator: "_")
                                .last
                                .flatMap(String.init)
                                .flatMap { $0.lowercased() }

                            return sdkString
                        }
                        .skipNil()
                        .single()?
                        .value

                    return sdkName
                }

                // Try to read what platfrom this binary is for. Attempt in order:
                // 1. Read `DTSDKName` from Info.plist.
                //  Some users are reporting that static frameworks don't have this key in the .plist,
                //  so we fall back and check the binary of the executable itself.
                // 2. Read the LC_VERSION_<PLATFORM> from the framework's binary executable file

                if let sdkNameFromBundle = bundle?.object(forInfoDictionaryKey: "DTSDKName") as? String {
                    return .success(sdkNameFromBundle)
                } else if let sdkNameFromExecutable = sdkNameFromExecutable() {
                    return .success(sdkNameFromExecutable)
                } else {
                    return .failure(readFailed("could not determine platform neither from DTSDKName key in plist nor from the framework's executable"))
                }
            }
            // Thus, the SDK name must be trimmed to match the platform name, e.g.
            // macosx10.10 -> macosx
            .map { sdkName in sdkName.trimmingCharacters(in: CharacterSet.letters.inverted) }
            .attemptMap { platform in SDK.from(string: platform).map { $0.platform } }
    }

    /// Sends the URL to each dSYM found in the given directory
    static func dSYMsInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        return filesInDirectory(directoryURL, "com.apple.xcode.dsym")
    }

    /// Sends the URL to each bcsymbolmap found in the given directory.
    static func BCSymbolMapsInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        return filesInDirectory(directoryURL)
            .filter { url in url.pathExtension == "bcsymbolmap" }
    }

    /// Sends the URLs of the bcsymbolmap files that match the given framework and are
    /// located somewhere within the given directory.
    static func BCSymbolMapsForFramework(_ frameworkURL: URL, inDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        return UUIDsForFramework(frameworkURL)
            .flatMap(.merge) { uuids -> SignalProducer<URL, CarthageError> in
                if uuids.isEmpty {
                    return .empty
                }
                func filterUUIDs(_ signal: Signal<URL, CarthageError>) -> Signal<URL, CarthageError> {
                    var remainingUUIDs = uuids
                    let count = remainingUUIDs.count
                    return signal
                        .filter { fileURL in
                            let basename = fileURL.deletingPathExtension().lastPathComponent
                            if let fileUUID = UUID(uuidString: basename) {
                                return remainingUUIDs.remove(fileUUID) != nil
                            } else {
                                return false
                            }
                        }
                        .take(first: count)
                }
                return self.BCSymbolMapsInDirectory(directoryURL)
                    .lift(filterUUIDs)
        }
    }

    /// Sends the URL of the dSYM whose UUIDs match those of the given framework, or
    /// errors if there was an error parsing a dSYM contained within the directory.
    static func dSYMForFramework(_ frameworkURL: URL, inDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
        return UUIDsForFramework(frameworkURL)
            .flatMap(.concat) { (frameworkUUIDs: Set<UUID>) in
                return self.dSYMsInDirectory(directoryURL)
                    .flatMap(.merge) { dSYMURL in
                        return UUIDsForDSYM(dSYMURL)
                            .filter { (dSYMUUIDs: Set<UUID>) in
                                return !dSYMUUIDs.isDisjoint(with: frameworkUUIDs)
                            }
                            .map { _ in dSYMURL }
                }
            }
            .take(first: 1)
    }

    /// Emits the framework URL if it matches the local Swift version and errors if not.
    static func checkSwiftFrameworkCompatibility(_ frameworkURL: URL, usingToolchain toolchain: String?) -> SignalProducer<URL, SwiftVersionError> {
        return SwiftToolchain.swiftVersion(usingToolchain: toolchain)
            .flatMap(.concat) { localSwiftVersion in
                return checkSwiftFrameworkCompatibility(frameworkURL, swiftVersion: localSwiftVersion)
        }
    }

    static func checkSwiftFrameworkCompatibility(_ frameworkURL: URL, swiftVersion: PinnedVersion) -> SignalProducer<URL, SwiftVersionError> {
        return frameworkSwiftVersion(frameworkURL)
            .attemptMap({ frameworkSwiftVersion -> Result<URL, SwiftVersionError> in
                return swiftVersion == frameworkSwiftVersion || isModuleStableAPI(swiftVersion.semanticVersion, frameworkSwiftVersion.semanticVersion, frameworkURL)
                    ? .success(frameworkURL)
                    : .failure(.incompatibleFrameworkSwiftVersions(local: swiftVersion, framework: frameworkSwiftVersion))
            })
    }

    /// Emits the framework URL if it is compatible with the build environment and errors if not.
    static func checkFrameworkCompatibility(_ frameworkURL: URL, usingToolchain toolchain: String?) -> SignalProducer<URL, SwiftVersionError> {
        if Frameworks.isSwiftFramework(frameworkURL) {
            return checkSwiftFrameworkCompatibility(frameworkURL, usingToolchain: toolchain)
        } else {
            return SignalProducer(value: frameworkURL)
        }
    }

    /// Emits the framework URL if it is compatible with the build environment and errors if not.
    static func checkFrameworkCompatibility(_ frameworkURL: URL, swiftVersion: PinnedVersion) -> SignalProducer<URL, SwiftVersionError> {
        if Frameworks.isSwiftFramework(frameworkURL) {
            return checkSwiftFrameworkCompatibility(frameworkURL, swiftVersion: swiftVersion)
        } else {
            return SignalProducer(value: frameworkURL)
        }
    }

    /// Determines whether a local swift version and a framework combination are considered module stable
    static func isModuleStableAPI(_ localSwiftVersion: SemanticVersion?, _ frameworkSwiftVersion: SemanticVersion?, _ frameworkURL: URL) -> Bool {
        guard let localSwiftVersion = localSwiftVersion, let frameworkSwiftVersion = frameworkSwiftVersion else { return false }

        let moduleStableSwiftVersion = SemanticVersion(5, 1, 0)
        return localSwiftVersion >= moduleStableSwiftVersion && frameworkSwiftVersion >= moduleStableSwiftVersion && hasSwiftInterfaceFile(frameworkURL)
    }

    static func hasSwiftInterfaceFile(_ frameworkURL: URL) -> Bool {
        guard
            let swiftModuleURL = frameworkURL.swiftmoduleURL(),
            let swiftModuleContents = try? FileManager.default.contentsOfDirectory(at: swiftModuleURL, includingPropertiesForKeys: nil, options: [])
        else { return false }

        let hasSwiftInterfaceFile = swiftModuleContents.contains { $0.lastPathComponent.contains("swiftinterface") }
        return hasSwiftInterfaceFile
    }

    /// Returns a signal of all architectures present in a given package.
    static func architecturesInPackage(_ packageURL: URL) -> SignalProducer<String, CarthageError> {
        return SignalProducer<URL, CarthageError> { () -> Result<URL, CarthageError> in Frameworks.binaryURL(packageURL) }
            .flatMap(.merge) { binaryURL -> SignalProducer<String, CarthageError> in
                let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-info", binaryURL.path])

                return lipoTask.launch()
                    .ignoreTaskData()
                    .mapError(CarthageError.taskError)
                    .map { String(data: $0, encoding: .utf8) ?? "" }
                    .flatMap(.merge) { output -> SignalProducer<String, CarthageError> in
                        var characterSet = CharacterSet.alphanumerics
                        characterSet.insert(charactersIn: " _-")

                        let scanner = Scanner(string: output)

                        if scanner.scanString("Architectures in the fat file:", into: nil) {
                            // The output of "lipo -info PathToBinary" for fat files
                            // looks roughly like so:
                            //
                            //     Architectures in the fat file: PathToBinary are: armv7 arm64
                            //
                            var architectures: NSString?

                            scanner.scanString(binaryURL.path, into: nil)
                            scanner.scanString("are:", into: nil)
                            scanner.scanCharacters(from: characterSet, into: &architectures)

                            let components = architectures?
                                .components(separatedBy: " ")
                                .filter { !$0.isEmpty }

                            if let components = components {
                                return SignalProducer(components)
                            }
                        }

                        if scanner.scanString("Non-fat file:", into: nil) {
                            // The output of "lipo -info PathToBinary" for thin
                            // files looks roughly like so:
                            //
                            //     Non-fat file: PathToBinary is architecture: x86_64
                            //
                            var architecture: NSString?

                            scanner.scanString(binaryURL.path, into: nil)
                            scanner.scanString("is architecture:", into: nil)
                            scanner.scanCharacters(from: characterSet, into: &architecture)

                            if let architecture = architecture {
                                return SignalProducer(value: architecture as String)
                            }
                        }

                        return SignalProducer(error: .invalidArchitectures(description: "Could not read architectures from \(packageURL.path)"))
                }
        }
    }

    /// Invokes otool -L for a given executable URL.
    ///
    /// - Parameter executableURL: URL to a valid executable.
    /// - Returns: Array of the Shared Library ID that are linked against given executable (`Alamofire`, `Realm`, etc).
    /// System libraries and dylibs are omited.
    static func linkedFrameworks(for executable: URL) -> SignalProducer<String, CarthageError> {
        return Task("/usr/bin/xcrun", arguments: ["otool", "-L", executable.path])
            .launch()
            .mapError(CarthageError.taskError)
            .ignoreTaskData()
            .filterMap { data -> String? in
                return String(data: data, encoding: .utf8)
            }
            .map(linkedFrameworks(from:))
            .flatten()
    }

    /// Stripping linked shared frameworks from
    /// @rpath/Alamofire.framework/Alamofire (compatibility version 1.0.0, current version 1.0.0)
    /// to Alamofire as well as filtering out system frameworks and various dylibs.
    /// Static frameworks and libraries won't show up here, so we can ignore them.
    ///
    /// - Parameter otoolOutput: Output of the otool -L
    /// - Returns: Array of Shared Framework IDs.
    static func linkedFrameworks(from otoolOutput: String) -> [String] {
        // Executable name matches c99 extended identifier.
        // This regex ignores dylibs but we don't need them.
        guard let regex = try? NSRegularExpression(pattern: "\\/([\\w_]+) ") else {
            preconditionFailure("Expected regular expression to be valid")
        }
        return otoolOutput.components(separatedBy: "\n").compactMap { value in
            let fullNSRange = NSRange(value.startIndex..<value.endIndex, in: value)
            if

                let match = regex.firstMatch(in: value, range: fullNSRange),
                match.numberOfRanges > 1,
                match.range(at: 1).length > 0
            {
                return Range(match.range(at: 1), in: value).map { String(value[$0]) }
            }
            return nil
        }
    }
    
    // Returns a map of undefined (external) symbols where the key is the name of the dependency and the value is the symbol.
    static func undefinedSymbols(frameworkURL: URL) -> Result<[String: Set<String>], CarthageError> {
        return CarthageResult.catching {
            let executableURL = try binaryURL(frameworkURL).get()
            
            //_$s11
            let outputData = try Task("/usr/bin/xcrun", arguments: ["nm", "-u", executableURL.path]).getStdOutData().flatMapError { _ -> Result<Data, CarthageError> in
                return .success(Data())
            }.get()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let demangledOutput = try Task("/usr/bin/xcrun", arguments: ["swift-demangle"]).getStdOutString(input: outputData).mapError(CarthageError.taskError).get()
            let symbolLines = output.components(separatedBy: .newlines)
            let demangledSymbolLines = demangledOutput.components(separatedBy: .newlines)
            var lineNumber = 0
            
            let result = symbolLines.reduce(into: [String: Set<String>]()) { map, line in
                let scanner = Scanner(string: line)
                scanner.charactersToBeSkipped = CharacterSet()
                var count = 0
                if scanner.scanString("_$s", into: nil), scanner.scanInt(&count), let moduleName = scanner.scan(count: count) {
                    let effectiveModuleName = extensionDefiningModule(demangledSymbol: demangledSymbolLines[lineNumber]) ?? moduleName
                    map[effectiveModuleName, default: Set<String>()].insert(line)
                }
                lineNumber += 1
            }
            return result
        }
    }
    
    private static func extensionDefiningModule(demangledSymbol: String) -> String? {
        if let extensionRange = demangledSymbol.range(of: "(extension in ") {
            var definingModule = String()
            for c in demangledSymbol[extensionRange.upperBound..<demangledSymbol.endIndex] {
                if c == ")" {
                    break
                }
                definingModule.append(c)
            }
            return definingModule
        }
        return nil
    }
    
    // Returns a map of defined symbols where the key is the name of the module and the value is the set of symbols.
    static func definedSymbols(frameworkURL: URL) -> SignalProducer<(String, Set<String>), CarthageError> {
        return SignalProducer.init { () -> Result<(String, Set<String>), CarthageError> in
            return CarthageResult.catching {
                                
                let executableURL = try binaryURL(frameworkURL).get()
                
                //_$s11
                let outputData = try Task("/usr/bin/xcrun", arguments: ["nm", "-U", executableURL.path]).getStdOutData().flatMapError { _ -> Result<Data, CarthageError> in
                    return .success(Data())
                }.get()
                
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let demangledOutput = try Task("/usr/bin/xcrun", arguments: ["swift-demangle"]).getStdOutString(input: outputData).mapError(CarthageError.taskError).get()
                let expectedModuleName = executableURL.lastPathComponent
                
                let symbolLines = output.components(separatedBy: .newlines)
                let demangledSymbolLines = demangledOutput.components(separatedBy: .newlines)
                
                var lineNumber = 0
                
                let result = symbolLines.reduce(into: Set<String>()) { set, line in
                    let scanner = Scanner(string: line)
                    scanner.charactersToBeSkipped = CharacterSet()
                    var count = 0
                    
                    /// hex, whitespace, string, whitespace, symbol
                    if scanner.scanHexInt64(nil),
                        scanner.scanCharacters(from: .whitespaces, into: nil),
                        scanner.scanCharacters(from: .alphanumerics, into: nil),
                        scanner.scanCharacters(from: .whitespaces, into: nil),
                        let symbolName = scanner.remainingSubstring.map(String.init),
                        scanner.scanString("_$s", into: nil),
                        scanner.scanInt(&count),
                        let moduleName = scanner.scan(count: count) {
                        
                        let effectiveModuleName = extensionDefiningModule(demangledSymbol: demangledSymbolLines[lineNumber]) ?? moduleName
                        if effectiveModuleName == expectedModuleName {
                            set.insert(symbolName)
                        }
                    }
                    lineNumber += 1
                }
                return (expectedModuleName, result)
            }
        }
    }

    // MARK: - Private methods

    /// Sends the URL to each file found in the given directory conforming to the
    /// given type identifier. If no type identifier is provided, all files are sent.
    private static func filesInDirectory(_ directoryURL: URL, _ typeIdentifier: String? = nil) -> SignalProducer<URL, CarthageError> {
        let producer = FileManager.default.reactive
            .enumerator(at: directoryURL, includingPropertiesForKeys: [ .typeIdentifierKey ], options: [ .skipsHiddenFiles, .skipsPackageDescendants ], catchErrors: true)
            .map { _, url in url }
        if let typeIdentifier = typeIdentifier {
            return producer
                .filter { url in
                    if let urlTypeIdentifier = url.typeIdentifier {
                        return UTTypeConformsTo(urlTypeIdentifier as CFString, typeIdentifier as CFString)
                    } else {
                        return false
                    }
            }
        } else {
            return producer
        }
    }

    /// Sends a set of UUIDs for each architecture present in the given URL.
    private static func UUIDsFromDwarfdump(_ url: URL) -> SignalProducer<Set<UUID>, CarthageError> {
        let dwarfdumpTask = Task("/usr/bin/xcrun", arguments: [ "dwarfdump", "--uuid", url.path ], useCache: true)

        return dwarfdumpTask.launch()
            .ignoreTaskData()
            .mapError(CarthageError.taskError)
            .map { String(data: $0, encoding: .utf8) ?? "" }
            // If there are no dSYMs (the output is empty but has a zero exit
            // status), complete with no values. This can occur if this is a "fake"
            // framework, meaning a static framework packaged like a dynamic
            // framework.
            .filter { !$0.isEmpty }
            .flatMap(.merge) { output -> SignalProducer<Set<UUID>, CarthageError> in
                // UUIDs are letters, decimals, or hyphens.
                var uuidCharacterSet = CharacterSet()
                uuidCharacterSet.formUnion(.letters)
                uuidCharacterSet.formUnion(.decimalDigits)
                uuidCharacterSet.formUnion(CharacterSet(charactersIn: "-"))

                let scanner = Scanner(string: output)
                var uuids = Set<UUID>()

                // The output of dwarfdump is a series of lines formatted as follows
                // for each architecture:
                //
                //     UUID: <UUID> (<Architecture>) <PathToBinary>
                //
                while !scanner.isAtEnd {
                    scanner.scanString("UUID: ", into: nil)

                    var uuidString: NSString?
                    scanner.scanCharacters(from: uuidCharacterSet, into: &uuidString)

                    if let uuidString = uuidString as String?, let uuid = UUID(uuidString: uuidString) {
                        uuids.insert(uuid)
                    }

                    // Scan until a newline or end of file.
                    scanner.scanUpToCharacters(from: .newlines, into: nil)
                }

                if !uuids.isEmpty {
                    return SignalProducer(value: uuids)
                } else {
                    return SignalProducer(error: .invalidUUIDs(description: "Could not parse UUIDs using dwarfdump from \(url.path)"))
                }
        }
    }
}
