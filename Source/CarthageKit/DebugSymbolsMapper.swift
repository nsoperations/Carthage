import Foundation
import ReactiveTask
import Result

/// Class with functionality to create plists in dsym resources for mapping the build location to the source location of debug symbols.
/// This is necessary because the absolute path of the original source files is stored in the dsyms. To be able
/// to debug with those symbols with a different source location, a mapping has to exist.
/// For the format see the original documentation: https://lldb.llvm.org/use/symbols.html
final class DebugSymbolsMapper {

    /// Creates plists for mapping the original source location of every architecture in the dsym at the specified url to the supplied source location.
    /// The framework at the specified URL is parsed automatically to detect the original source location.
    /// Upon success a plist for each architecture with corresponding uuid is written to the Resources directory of the dsym bundle with the mappings in place.
    ///
    /// - Parameter frameworkURL: The url pointing to the root directory of the framework
    /// - Parameter dsymURL: The url pointing to the root of the corresponding expanded dsym archive (unzipped)
    /// - Parameter sourceURL: The url pointing to the root of the local source tree
    /// - Parameter urlPrefixMapping: Optional mapping to perform to replace a url path pefix with a different prefix for frameworkURL and dsymURL
    /// - Returns: Empty result if successful or a CarthageError on failure.
    static func mapSymbolLocations(frameworkURL: URL, dsymURL: URL, sourceURL: URL, urlPrefixMapping: (URL, URL)? = nil) -> Result<(), CarthageError> {
        do {
            guard frameworkURL.isExistingDirectory else {
                throw CarthageError.invalidFramework(frameworkURL, description: "No framework found at this location")
            }
            guard dsymURL.isExistingDirectory else {
                throw CarthageError.invalidDebugSymbols(dsymURL, description: "No debug symbols found at this location")
            }

            let buildSourceURL = try findBuildSourceURL(frameworkURL: frameworkURL, sourceURL: sourceURL)
            let binaryUUIDs = try verifyUUIDs(frameworkURL: frameworkURL, dsymURL: dsymURL)

            try generatePlistForDsym(dsymURL:dsymURL, frameworkURL: frameworkURL, sourceURL: sourceURL, buildSourceURL: buildSourceURL, binaryUUIDs: binaryUUIDs, urlPrefixMapping: urlPrefixMapping)
            return .success(())
        } catch let error as CarthageError {
            return .failure(error)
        } catch {
            return .failure(CarthageError.internalError(description: error.localizedDescription))
        }
    }

    // MARK: - Private

    private static func findBuildSourceURL(frameworkURL: URL, sourceURL: URL) throws -> URL {
        let binaryURL = try normalizedBinaryURL(url: frameworkURL)
        let stdoutString = try Task(launchCommand: "/usr/bin/xcrun nm -pa \"\(binaryURL.path)\"").getStdOutString().mapError(CarthageError.taskError).get()
        let lines = stdoutString.split(separator: "\n")
        var buildSourceURL: URL?

        for line in lines {
            let lineComponents = line.split { CharacterSet.whitespaces.contains($0) }
            let sourceLine: String? = (lineComponents.count > 5 && lineComponents[4] == "SO") ? String(lineComponents[5]) : nil

            if let definedSourceLine = sourceLine {
                if definedSourceLine.hasPrefix("/") {
                    buildSourceURL = URL(fileURLWithPath: definedSourceLine)
                } else if let definedBuildSourceURL = buildSourceURL {
                    buildSourceURL = definedBuildSourceURL.appendingPathComponent(definedSourceLine)
                }
            } else if let definedBuildSourceURL = buildSourceURL {
                if let matchURL = matchURL(sourceURL: sourceURL, buildSourceURL: definedBuildSourceURL) {
                    return matchURL
                }
                buildSourceURL = nil
            }
        }
        if let definedBuildSourceURL = buildSourceURL, let matchURL = matchURL(sourceURL: sourceURL, buildSourceURL: definedBuildSourceURL) {
            return matchURL
        }
        throw CarthageError.invalidFramework(frameworkURL, description: "Could not find appropriate debug symbols mapping for source path: \(sourceURL.path)")
    }

    private static func matchURL(sourceURL: URL, buildSourceURL: URL) -> URL? {
        var trailingPathComponents = [String]()
        var matchURL = buildSourceURL

        while !matchURL.isRoot && matchURL.lastPathComponent != ".." {
            trailingPathComponents.append(matchURL.lastPathComponent)
            matchURL = matchURL.deletingLastPathComponent()
            let candidateURL = sourceURL.appendingPathComponents(trailingPathComponents.reversed())
            if candidateURL.isExistingFile {
                return matchURL
            }
        }
        return nil
    }

    private static func uuidsOfDwarf(_ binaryURL: URL) throws -> [String: String] {

        // The output of dwarfdump is a series of lines formatted as follows
        // for each architecture:
        //
        //     UUID: <UUID> (<Architecture>) <PathToBinary>
        //

        let normalizedURL = try normalizedBinaryURL(url: binaryURL)
        let task = Task("/usr/bin/xcrun", arguments: ["dwarfdump", "--uuid", normalizedURL.path], useCache: true)

        let stdOutString = try task.getStdOutString().mapError(CarthageError.taskError).get()

        let lines = stdOutString.split(separator: "\n")

        var archsToUUIDs = [String: String]()

        for line in lines {
            let elements = line.split(separator: " ")
            if elements.count >= 4 {
                archsToUUIDs[elements[2].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")] = String(elements[1])
            }
        }
        return archsToUUIDs
    }

    /// Verifies whether the UUIDs from the binary match the UUIDs from the debug symbols
    private static func verifyUUIDs(frameworkURL: URL, dsymURL: URL) throws -> [String: String] {

        let binaryUUIDs = try uuidsOfDwarf(frameworkURL)

        guard !binaryUUIDs.isEmpty else {
            throw CarthageError.invalidFramework(frameworkURL, description: "No architectures found")
        }

        let dsymUUIDs = try uuidsOfDwarf(dsymURL)

        for (arch, uuid) in binaryUUIDs {
            guard let dsymUUID = dsymUUIDs[arch] else {
                throw CarthageError.internalError(description: "Could not find \(arch) architecture in dSYM")
            }
            guard dsymUUID == uuid else {
                throw CarthageError.invalidUUIDs(description: "UUID mismatch between framework at \(frameworkURL.path) and debug symbols at \(dsymURL.path) for architecture \(arch): binary UUID=\(uuid), dsym UUID=\(dsymUUID)")
            }
        }

        return binaryUUIDs
    }

    /// Generates the relevant plist files in the dsym bundle at the specified URL using the arguments specified.
    private static func generatePlistForDsym(dsymURL: URL, frameworkURL: URL, sourceURL: URL, buildSourceURL: URL, binaryUUIDs: [String: String], urlPrefixMapping: (URL, URL)?) throws {
        for (arch, uuid) in binaryUUIDs {

            var dsymPath = try normalizedBinaryURL(url: dsymURL).resolvingSymlinksInPath().path
            var frameworkPath = try normalizedBinaryURL(url: frameworkURL).resolvingSymlinksInPath().path

            if let mapping = urlPrefixMapping {
                let sourcePath = mapping.0.resolvingSymlinksInPath().path
                let targetPath = mapping.1.resolvingSymlinksInPath().path
                dsymPath.replacePrefix(sourcePath, with: targetPath)
                frameworkPath.replacePrefix(sourcePath, with: targetPath)
            }

            let plistDict: [String: Any] = [
                "DBGArchitecture": arch,
                "DBGBuildSourcePath": buildSourceURL.absoluteURL.path,
                "DBGSourcePath": sourceURL.absoluteURL.path,
                "DBGDSYMPath": dsymPath,
                "DBGSymbolRichExecutable": frameworkPath,
            ]
            let plistURL = dsymURL.appendingPathComponents(["Contents", "Resources", "\(uuid).plist"])
            try writePlist(at: plistURL, plistObject: plistDict as Any)
        }
    }

    /// Returns the absolute binary file URL for the directory at the specified path, which should be a .framework directory or a .dsym directory.
    /// Will throw an error for any other url.
    private static func normalizedBinaryURL(url: URL) throws -> URL {
        if url.path.lowercased().hasSuffix(".framework") {
            let macInfoPlist = url.appendingPathComponent("Resources").appendingPathComponent("Info.plist")
            let otherInfoPlist = url.appendingPathComponent("Info.plist")
            let plist: Any
            if macInfoPlist.isExistingFile {
                plist = try readPlist(at: macInfoPlist)
            } else {
                plist = try readPlist(at: otherInfoPlist)
            }
            guard let plistDict = plist as? [String: Any] else {
                throw CarthageError.invalidFramework(url, description: "Unrecognized Info.plist format, should be a dictionary with string keys")
            }
            guard let value = plistDict["CFBundleExecutable"], let executableName = value as? String else {
                throw CarthageError.invalidFramework(url, description: "Info.plist does not contain CFBundleExecutable key or value is not a String")
            }
            return url.appendingPathComponent(executableName).absoluteURL
        } else if url.path.lowercased().hasSuffix(".dsym") {
            let dwarfURL = url.appendingPathComponents(["Contents", "Resources", "DWARF"])
            do {
                let fileNames = try FileManager.default.contentsOfDirectory(atPath: dwarfURL.path)
                if fileNames.isEmpty {
                    throw CarthageError.invalidDebugSymbols(url, description: "Could not find DWARF file")
                }
                if fileNames.count > 1 {
                    throw CarthageError.invalidDebugSymbols(url, description: "Found more than one DWARF file")
                }
                return dwarfURL.appendingPathComponent(fileNames[0]).absoluteURL
            } catch let error as NSError {
                throw CarthageError.readFailed(dwarfURL, error)
            }
        }
        throw CarthageError.internalError(description: "Unrecognized url specified to normalizedBinaryURL: \(url)")
    }

    /// Reads the plist at the specified url
    private static func readPlist(at url: URL) throws -> Any {
        do {
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)
            return plist
        } catch {
            throw CarthageError.readFailed(url, error as NSError)
        }
    }

    /// Writes the plist at the specified URL
    private static func writePlist(at url: URL, plistObject: Any) throws {
        do {
            let plistData = try PropertyListSerialization.data(fromPropertyList: plistObject, format: .xml, options: 0)
            try plistData.write(to: url, options: .atomic)
        } catch {
            throw CarthageError.writeFailed(url, error as NSError)
        }
    }
}

extension String {
    fileprivate mutating func replacePrefix(_ prefix: String, with replacement: String) {
        if self.hasPrefix(prefix) {
            self = replacement + self.substring(from: prefix.count)
        }
    }
}
