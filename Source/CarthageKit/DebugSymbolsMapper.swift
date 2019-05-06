import Foundation
import ReactiveTask

/// Class with functionality to create a Plist for mapping the build location to the source location of debug symbols
final class DebugSymbolsMapper {
    
    static func mapSymbolLocations(frameworkURL: URL, dsymURL: URL, sourceURL: URL) throws {
        let sourcePathToMap: String = try findSourcePathToMap(frameworkURL: frameworkURL, sourceURL: sourceURL)
        
        let binaryUUIDs = try uuidsOfDwarf(frameworkURL)
        let dsymUUIDs = try uuidsOfDwarf(dsymURL)
        
        try verifyUUIDs(binaryUUIDs: binaryUUIDs, dsymUUIDs: dsymUUIDs)
        
        try generatePlistForDsym(dsymURL: dsymURL, frameworkURL: frameworkURL, sourceURL: sourceURL, sourcePathToMap: sourcePathToMap, binaryUUIDs: binaryUUIDs)
    }
    
    // MARK: - Private
    
    private static func findSourcePathToMap(frameworkURL: URL, sourceURL: URL) throws -> String {
        let pathSeparator: Character = "/"
        
        let binaryURL = try normalizedBinaryURL(url: frameworkURL)
        let stdoutString = try Task("/usr/bin/xcrun", arguments: ["nm", "-pa", binaryURL.path, "|", "grep", "SO /"]).getStdOutString().get()
        let sourcePath = sourceURL.path
        
        let lines = stdoutString.split(separator: "\n")
        for line in lines {
            let components = line.split { $0.isWhitespace }
            if components.count > 5 {
                let originalPath = components[5]
                let originalPathComponents = originalPath.split(separator: pathSeparator)
                var pathSuffix = ""
                
                for i in (0..<originalPathComponents.count).reversed() {
                    let comp = originalPathComponents[i]
                    if !comp.isEmpty {
                        pathSuffix = String(pathSuffix.isEmpty ? comp : comp + pathSeparator.description + pathSuffix)
                        
                        let candidatePath = sourcePath + pathSeparator.description + pathSuffix
                        
                        var isDirectory: ObjCBool = false
                        
                        let fileExists = FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDirectory)
                        
                        if fileExists && isDirectory.boolValue {
                            var ret = ""
                            for j in 0..<i {
                                if !ret.isEmpty {
                                    ret += pathSeparator.description
                                }
                                ret += originalPathComponents[j]
                            }
                            return ret
                        }
                    }
                }
            }
        }
        
        throw CarthageError.internalError(description: "Unable to find path match")
    }
    
    private static func uuidsOfDwarf(_ binaryURL: URL) throws -> [String: String] {
        
        let task = Task("/usr/bin/xcrun", arguments: ["dwarfdump", "--uuid", binaryURL.path])
        
        let stdOutString = try task.getStdOutString().get()
        
        let lines = stdOutString.split(separator: "\n")
        
        var archsToUUIDs = [String: String]()
        
        for line in lines {
            let elements = line.split(separator: " ")
            if elements.count >= 4 {
                archsToUUIDs[elements[2].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")] = String(elements[1])
            }
        }
        
        if archsToUUIDs.count == 0 {
            throw CarthageError.internalError(description: "Unable to obtain UUIDs for file at location \(binaryURL.path)")
        }
        
        return archsToUUIDs
    }
    
    private static func verifyUUIDs(binaryUUIDs: [String: String], dsymUUIDs: [String: String]) throws {
        for (arch, uuid) in binaryUUIDs {
            guard let dsymUUID = dsymUUIDs[arch] else {
                throw CarthageError.internalError(description: "Could not find \(arch) architecture in dSYM")
            }
            guard dsymUUID == uuid else {
                throw CarthageError.internalError(description: "UUID mismatch for architecture \(arch), binary UUID=\(uuid), dsym UUID=\(dsymUUID)")
            }
        }
    }
    
    private static func generatePlistForDsym(dsymURL: URL, frameworkURL: URL, sourceURL: URL, sourcePathToMap: String, binaryUUIDs: [String: String]) throws {
        
        for (arch, uuid) in binaryUUIDs {
            let plistDict: [String: String] = [
                "DBGArchitecture": arch,
                "DBGBuildSourcePath": sourcePathToMap,
                "DBGSourcePath": sourceURL.path,
                "DBGDSYMPath": try normalizedBinaryURL(url: dsymURL).path,
                "DBGSymbolRichExecutable": try normalizedBinaryURL(url: frameworkURL).path
            ]
            let plistURL = dsymURL.appendingPathComponents(["Contents", "Resources", "\(uuid).plist"])
            writePlist(at: plistURL, dict: plistDict)
        }
    }
    
    private static func normalizedBinaryURL(url: URL) throws -> URL {
        var result = url
        if url.path.lowercased().hasSuffix(".framework") {
            let plistDict: [String: String] = try readPlist(at: url.appendingPathComponent("Info.plist"))
            guard let executableName = plistDict["CFBundleExecutable"] else {
                throw CarthageError.internalError(description: "Info.plist for framework at \(url.path) does not contain CFBundleExecutable key")
            }
            result = url.appendingPathComponent(executableName)
            
        } else if url.path.lowercased().hasSuffix(".dsym") {
            let dwarfURL = url
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("DWARF")
            let fileNames = try FileManager.default.contentsOfDirectory(atPath: dwarfURL.path)
            
            if fileNames.count != 1 {
                throw CarthageError.internalError(description: "Found more than one dwarf file in dsym at path \(url.path)")
            }
        }
        return result
    }
    
    private static func readPlist(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)
        guard let plistDict = plist as? [String: String] else {
            throw CarthageError.internalError(description: "Unrecognized plist format, should be a dictionary of strings")
        }
        return plistDict
    }
    
    private static func writePlist(at url: URL, dict: [String: String]) throws {
        let plistData: Data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try plistData.write(to: url, options: .atomic)
    }
}

extension URL {
    
    fileprivate func appendingPathComponents(_ components: [String]) -> URL {
        var ret = self
        for component in components {
            ret = ret.appendingPathComponent(component)
        }
        return ret
    }
}
