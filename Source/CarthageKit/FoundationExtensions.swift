import Foundation

extension Collection where Element: Hashable {

    func unique() -> [Element] {
        var set = Set<Element>(minimumCapacity: count)

        return filter {
            return set.insert($0).inserted
        }
    }
}

extension FileManager {

    public func allDirectories(at directoryURL: URL, ignoringExtensions: Set<String> = []) -> [URL] {
        func isDirectory(at url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }

        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard
            directoryURL.isFileURL,
            isDirectory(at: directoryURL),
            let enumerator = self.enumerator(at: directoryURL, includingPropertiesForKeys: keys, options: options)
            else
        {
            return []
        }

        var result: [URL] = [directoryURL]

        for url in enumerator {
            if let url = url as? URL, isDirectory(at: url) {
                if !url.pathExtension.isEmpty && ignoringExtensions.contains(url.pathExtension) {
                    enumerator.skipDescendants()
                } else {
                    result.append(url)
                }
            }
        }

        return result.map { $0.standardizedFileURL }
    }
}

extension NSLock {
    func locked<T>(_ perform: () throws -> T) rethrows -> T {
        self.lock()
        defer {
            self.unlock()
        }
        return try perform()
    }
}

extension String {

    private static let gitSHACharacterSet = CharacterSet(charactersIn: "0123456789abcdef")

    /// Strips off a prefix string, if present.
    internal func stripping(prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(self.dropFirst(prefix.count))
    }

    /// Strips off a trailing string, if present.
    internal func stripping(suffix: String) -> String {
        if hasSuffix(suffix) {
            let end = index(endIndex, offsetBy: -suffix.count)
            return String(self[startIndex..<end])
        } else {
            return self
        }
    }

    internal var isGitCommitSha: Bool {
        return self.count == 40 && String.gitSHACharacterSet.isSuperset(of: CharacterSet(charactersIn: self))
    }

    /// Returns true if self contain any of the characters from the given set
    internal func containsAny(_ characterSet: CharacterSet) -> Bool {
        return self.rangeOfCharacter(from: characterSet) != nil
    }

    internal func appendingPathComponent(_ component: String) -> String {
        return (self as NSString).appendingPathComponent(component)
    }

    internal func appendingPathExtension(_ pathExtension: String) -> String {
        return (self as NSString).appendingPathExtension(pathExtension)!
    }

    internal var deletingLastPathComponent: String {
        return (self as NSString).deletingLastPathComponent
    }

    internal var lastPathComponent: String {
        return (self as NSString).lastPathComponent
    }

    func substring(from: Int) -> Substring {
        return self[self.index(self.startIndex, offsetBy: from)...]
    }

    func substring(from: Int, length: Int) -> Substring {
        let start = self.index(self.startIndex, offsetBy: from)
        let end = self.index(start, offsetBy: length)
        return self[start..<end]
    }

    func substring(to: Int) -> Substring {
        let end = self.index(self.startIndex, offsetBy: to)
        return self[self.startIndex..<end]
    }

    func substring(with range: Range<Int>) -> Substring {
        return substring(from: range.startIndex, length: range.endIndex - range.startIndex)
    }
    
    func character(at: Int) -> Character {
        return self[index(startIndex, offsetBy: at)]
    }
    
    func firstMatchGroups(regex: NSRegularExpression) -> [String]? {
        
        let fullRange = NSRange(self.startIndex..., in: self)
        
        guard let match = regex.firstMatch(in: self, options: [], range: fullRange) else {
            return nil
        }
        
        var matches = [String]()
        for i in 0..<match.numberOfRanges {
            guard let range = Range(match.range(at: i), in: self) else {
                fatalError("Expected range to not be nil")
            }
            let matchGroup = self[range]
            matches.append(String(matchGroup))
        }
        return matches
    }
    
    func firstMatchGroup(at index: Int, regex: NSRegularExpression) -> String? {
        
        let fullRange = NSRange(self.startIndex..., in: self)
        
        guard let match = regex.firstMatch(in: self, options: [], range: fullRange) else {
            return nil
        }
        
        guard index < match.numberOfRanges else {
            return nil
        }
        
        guard let range = Range(match.range(at: index), in: self) else {
            fatalError("Expected range to not be nil")
        }
        return String(self[range])
    }
}

extension Data {

    private static let hexCharacterLookupTable: [Character] = [
        "0",
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
        "7",
        "8",
        "9",
        "a",
        "b",
        "c",
        "d",
        "e",
        "f",
    ]

    var hexString: String {
        return self.reduce(into: String(), { result, byte in
            let c1: Character = Data.hexCharacterLookupTable[Int(byte >> 4)]
            let c2: Character = Data.hexCharacterLookupTable[Int(byte & 0x0F)]
            result.append(c1)
            result.append(c2)
        })
    }
}

extension Scanner {
    /// Returns the current line being scanned.
    internal var currentLine: String {
        // Force Foundation types, so we don't have to use Swift's annoying
        // string indexing.
        let nsString = string as NSString
        let scanRange: NSRange = NSRange(location: scanLocation, length: 0)
        let lineRange: NSRange = nsString.lineRange(for: scanRange)

        return nsString.substring(with: lineRange)
    }

    /// The string (as `Substring?`) that is left to scan.
    ///
    /// Accessing this variable will not advance the scanner location.
    ///
    /// - returns: `nil` in the unlikely event `self.scanLocation` splits an extended grapheme cluster.
    internal var remainingSubstring: Substring? {
        return Range(
            NSRange(
                location: self.scanLocation /* our UTF-16 offset */,
                length: (self.string as NSString).length - self.scanLocation
            ),
            in: self.string
            ).map {
                self.string[$0]
        }
    }
    
    func scan(count: Int) -> String? {
        let nsString = string as NSString
        
        guard scanLocation + count <= nsString.length else {
            return nil
        }
        
        let scanRange = NSRange(location: scanLocation, length: count)
        return nsString.substring(with: scanRange)
    }
}

extension URL {
    /// The type identifier of the receiver, or an error if it was unable to be
    /// determined.
    internal var typeIdentifier:
        String? {
        do {
            return try resourceValues(forKeys: [ .typeIdentifierKey ]).typeIdentifier
        } catch {
            return nil
        }
    }

    public func hasSubdirectory(_ possibleSubdirectory: URL) -> Bool {
        let standardizedSelf = self.standardizedFileURL
        let standardizedOther = possibleSubdirectory.standardizedFileURL

        let path = standardizedSelf.pathComponents
        let otherPath = standardizedOther.pathComponents
        if scheme == standardizedOther.scheme && path.count <= otherPath.count {
            return Array(otherPath[path.indices]) == path
        }

        return false
    }

    fileprivate func volumeSupportsFileCloning() throws -> Bool {
        guard #available(macOS 10.12, *) else { return false }

        let key = URLResourceKey.volumeSupportsFileCloningKey
        let values = try self.resourceValues(forKeys: [key]).allValues

        func error(failureReason: String) -> NSError {
            return NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileReadUnknown.rawValue,
                userInfo: [NSURLErrorKey: self, NSLocalizedFailureReasonErrorKey: failureReason]
            )
        }

        guard values.count == 1 else {
            throw error(failureReason: "Expected single resource value: «actual count: \(values.count)».")
        }

        guard let volumeSupportsFileCloning = values[key] as? NSNumber else {
            throw error(failureReason: "Unable to extract a NSNumber from «\(String(describing: values.first))».")
        }

        return volumeSupportsFileCloning.boolValue
    }

    /// Returns the first `URL` to match `<self>/Headers/*-Swift.h`. Otherwise `nil`.
    internal func swiftHeaderURL() -> URL? {
        let headersURL = self.appendingPathComponent("Headers", isDirectory: true).resolvingSymlinksInPath()
        let dirContents = try? FileManager.default.contentsOfDirectory(at: headersURL, includingPropertiesForKeys: [], options: [])
        return dirContents?.first { $0.lastPathComponent.hasSuffix("-Swift.h") }
    }

    internal func candidateSwiftHeaderURLs() -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [URLResourceKey.nameKey, URLResourceKey.isRegularFileKey]

        var candidateURLs = [URL]()

        guard let enumerator = fileManager.enumerator(at: self, includingPropertiesForKeys: Array(resourceKeys), options: []) else {
            return candidateURLs
        }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                resourceValues.isRegularFile == true,
                let name = resourceValues.name,
                name.hasSuffix(".h")
                else {
                    continue
            }

            candidateURLs.append(fileURL)
        }

        let frameworkName = self.deletingPathExtension().lastPathComponent

        return candidateURLs.sorted { $0.swiftHeaderProbability(frameworkName: frameworkName) > $1.swiftHeaderProbability(frameworkName: frameworkName) }
    }

    /// Returns the first `URL` to match `<self>/Modules/*.swiftmodule`. Otherwise `nil`.
    internal func swiftmoduleURL() -> URL? {
        let headersURL = self.appendingPathComponent("Modules", isDirectory: true).resolvingSymlinksInPath()
        let dirContents = try? FileManager.default.contentsOfDirectory(at: headersURL, includingPropertiesForKeys: [], options: [])
        return dirContents?.first { $0.absoluteString.contains("swiftmodule") }
    }

    internal func appendingPathComponents(_ components: [String]) -> URL {
        var ret = self
        for component in components {
            ret = ret.appendingPathComponent(component)
        }
        return ret
    }

    internal func deletingLastPathComponents(count: Int) -> URL {
        var ret = self
        for _ in 0..<count {
            ret = ret.deletingLastPathComponent()
        }
        return ret
    }

    internal var isGitDirectory: Bool {
        return self.appendingPathComponent(".git").isExistingDirectory
    }

    internal var isExistingDirectory: Bool {
        var isDirectory: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: self.path, isDirectory: &isDirectory)
        return fileExists && isDirectory.boolValue
    }

    internal var isExistingFile: Bool {
        var isDirectory: ObjCBool = true
        let fileExists = FileManager.default.fileExists(atPath: self.path, isDirectory: &isDirectory)
        return fileExists && !isDirectory.boolValue
    }

    internal var isExistingFileOrDirectory: Bool {
        var isDirectory: ObjCBool = true
        let fileExists = FileManager.default.fileExists(atPath: self.path, isDirectory: &isDirectory)
        return fileExists
    }

    internal var isRoot: Bool {
        let path = self.path
        return path.isEmpty || path == "/"
    }

    internal var modificationDate: Date? {
        let key: URLResourceKey = .contentModificationDateKey
        let attributes = try? self.resourceValues(forKeys: [key])
        return attributes?.contentModificationDate
    }

    internal func removeIgnoringErrors() {
        _ = try? FileManager.default.removeItem(at: self)
    }

    fileprivate func swiftHeaderProbability(frameworkName: String) -> Int {
        var result = 0
        let fileName = self.lastPathComponent
        let isDefaultSwiftHeaderName = fileName.hasSuffix("-Swift.h")
        let includesFrameworkName = fileName.contains(frameworkName)
        let isInHeaderDirectory = self.deletingLastPathComponent().lastPathComponent == "Headers"

        if isDefaultSwiftHeaderName {
            result += 10
        }

        if includesFrameworkName {
            result += 5
        }

        if isInHeaderDirectory {
            result += 2
        }
        return result
    }

    internal func pathComponentsRelativeTo(_ baseURL: URL) -> [String]? {
        var url = self
        var relativeComponents = [String]()
        while !url.isRoot && url.lastPathComponent != ".." {
            if baseURL.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path {
                return relativeComponents.reversed()
            }
            relativeComponents.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    internal func pathRelativeTo(_ baseURL: URL) -> String? {
        guard let relativePathComponents = self.pathComponentsRelativeTo(baseURL) else {
            return nil
        }
        guard !relativePathComponents.isEmpty else {
            return "."
        }
        return relativePathComponents.reduce("", { (relativePath, component) -> String in
            return relativePath.appendingPathComponent(component)
        })
    }

    internal func isAncestor(of url: URL) -> Bool {
        let path = self.resolvingSymlinksInPath().path
        var normalizedUrl = url.resolvingSymlinksInPath()
        while !normalizedUrl.isRoot && normalizedUrl.lastPathComponent != ".." {
            if normalizedUrl.path == path {
                return true
            }
            normalizedUrl = normalizedUrl.deletingLastPathComponent()
        }
        return false
    }
}

extension CharacterSet {
    func contains(_ character: Character) -> Bool {
        guard let firstScalar = character.unicodeScalars.first else {
            return false
        }
        return self.contains(firstScalar)
    }
}
