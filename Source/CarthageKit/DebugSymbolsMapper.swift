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
        
        
        /*
 """
 
 :type binary_path: string - can be a framework or a valid dwarf binary, FAT or thin.
 :type source_path: string
 """
 binary_path = normalize_binary_path(binary_path)
 
 proc = subprocess.Popen('nm -pa "%s" | grep "SO /"' % binary_path, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
 (stdoutputdata, stderrdata) = proc.communicate()
 
 lines = stdoutputdata.split("\n")
 
 for line in lines:
 split_result = re.split(r"\s+", line)
 # A line looks like this
 # 0000000000000000 - 00 0000    SO /potential/path/in/remote/machine
 if len(split_result) >= 5:
 potential_original_path = split_result[5]
 potential_original_path_fragments = potential_original_path.split("/")
 
 potential_path_suffix = ""
 
 #
 # Here's an example of how the algorithm below works:
 #
 # let's assume that source_path             == /my/path
 #                   potential_original_path == /remote/place/foo/bar/baz
 #
 # Then we attempt to see if /my/path/baz exists, if not then /my/path/bar/baz, and then
 # /my/path/foo/bar/baz and if it does we return /remote/place/
 #
 for i in reversed(xrange(len(potential_original_path_fragments))):
 if potential_original_path_fragments[i] != "":
 potential_path_suffix = path.join(potential_original_path_fragments[i], potential_path_suffix)
 
 if path.isdir(path.join(source_path, potential_path_suffix)):
 return potential_original_path[0:potential_original_path.index(potential_path_suffix)-1]
 
 assert False, "Unable to find path match, sorry :-( failing miserably!"
 */
        
        let binaryURL = try normalizedBinaryURL(url: frameworkURL)
        let stdoutString = try Task("/usr/bin/xcrun", arguments: ["nm", "-pa", binaryURL.path, "|", "grep", "SO /"]).getStdOutString().get()
        
        let lines = stdoutString.split(separator: "\n")
        for line in lines {
            let components = line.split { $0.isWhitespace }
            if components.count > 5 {
                let potentialOriginalPath = components[5]
                let potentialOriginalPathComponents = potentialOriginalPath.split(separator: "/")
                var potentialPathSuffixComponents = [String]()
                
                for i in (0..<potentialOriginalPathComponents.count).reversed() {
                    let comp = potentialOriginalPathComponents[i]
                    if !comp.isEmpty {
                        potentialPathSuffixComponents.insert(String(comp), at: 0)
                        
                        let candidateURL = sourceURL.appendingPathComponents(potentialPathSuffixComponents)
                        FileManager.
                    }
                }
            }
        }
        
        return ""
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
        
    }
    
    private static func generatePlistForDsym(dsymURL: URL, frameworkURL: URL, sourceURL: URL, sourcePathToMap: String, binaryUUIDs: [String]) throws {
        
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
    
    private static func readPlist(at: URL) throws -> [String: String] {
        return [String: String]()
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
