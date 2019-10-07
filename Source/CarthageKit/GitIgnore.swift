//
//  GitIgnore.swift
//  CarthageKit
//
//  Created by Werner Altewischer on 05/10/2019.
//

import Foundation
import wildmatch

/// Class which parses a git ignore file and validates patterns against it
final class GitIgnore {

    private let parent: GitIgnore?
    private var negatedPatterns = [Pattern]()
    private var patterns = [Pattern]()
    
    init(parent: GitIgnore? = nil) {
        self.parent = parent
    }

    convenience init(string: String, parent: GitIgnore? = nil) {
        self.init(parent: parent)
        addPatterns(from: string)
    }

    convenience init(file: URL, parent: GitIgnore? = nil) throws {
        self.init(parent: parent)
        try addPatterns(from: file)
    }
    
    func addPatterns(from file: URL) throws {
        let string = try String(contentsOf: file, encoding: .utf8)
        addPatterns(from: string)
    }
    
    func addPatterns(from string: String) {
        let components = string.components(separatedBy: .newlines)
        
        for component in components {
            addPattern(component)
        }
    }
    
    func addPattern(_ pattern: String) {
        guard let (patternString, isNegated, onlyDirectories) = GitIgnore.normalizedPattern(pattern) else {
            return
        }
        if let pattern = Pattern(string: patternString, onlyDirectories: onlyDirectories) {
            if isNegated {
                negatedPatterns.append(pattern)
            } else {
                patterns.append(pattern)
            }
        }
    }
    
    func matches(relativePath: String, isDirectory: Bool) -> Bool {

        let hasMatchingPattern: (Pattern) -> Bool = { $0.matches(relativePath: relativePath, isDirectory: isDirectory) }

        guard !negatedPatterns.contains(where: hasMatchingPattern) else {
            return false
        }

        guard !patterns.contains(where: hasMatchingPattern) else {
            return true
        }

        if let parent = self.parent {
            return parent.matches(relativePath: relativePath, isDirectory: isDirectory)
        } else {
            return false
        }
    }

    private static let whiteSpaceSet = CharacterSet.whitespaces

    private static func normalizedPattern(_ pattern: String) -> (pattern: String, negated: Bool, onlyDirectories: Bool)? {

        var isNegated = false
        var onlyDirectories = false
        var patternString = pattern.trimmingCharacters(in: whiteSpaceSet)

        if patternString.hasSuffix("\\") {
            // Ends with escape, check if a whitespace came after it. If so, append it back
            if let index1 = pattern.lastIndex(of: "\\"), index1 < pattern.index(before: pattern.endIndex) {
                let c = pattern[pattern.index(after: index1)]
                if whiteSpaceSet.contains(c) {
                    patternString.append(c)
                }
            }
        } else if patternString.hasSuffix("/") {
            onlyDirectories = true
            patternString = String(patternString.dropLast(1))
        }

        // Normalize the patternString such that it can be used for a wild card match
        if patternString.hasPrefix("#") || patternString.isEmpty {
            return nil
        } else if patternString.hasPrefix("!") {
            // Negated pattern
            isNegated = true
            patternString = String(patternString.substring(from: 1))
        } else if patternString.hasPrefix("\\") && patternString.count > 1 {
            // Possible escape
            let secondChar = patternString.character(at: 1)
            switch secondChar {
            case "!", "#", " ":
                // Escaped first character
                patternString = String(patternString.substring(from: 1))
            default:
                break
            }
        }

        if patternString.hasPrefix("/") {
            // Chop the leading slash
            patternString = String(patternString.substring(from: 1))
        } else if !patternString.contains("/") {
            // No slash is considered to be a match in all directories
            patternString = "**/" + patternString
        }

        return (patternString, isNegated, onlyDirectories)
    }
}

private struct Pattern {
    
    private let rawPattern: [CChar]
    private let onlyDirectories: Bool
    
    init?(string: String, onlyDirectories: Bool) {
        guard let cString = string.cString(using: .utf8) else {
            return nil
        }
        self.rawPattern = cString
        self.onlyDirectories = onlyDirectories
    }
    
    func matches(relativePath: String, isDirectory: Bool) -> Bool {
        if !isDirectory && self.onlyDirectories {
            return false
        }

        return relativePath.withCString { text -> Bool in
            switch wildmatch(rawPattern, text, UInt32(WM_PATHNAME)) {
            case WM_MATCH:
                return true
            case WM_NOMATCH:
                return false
            default:
                return false
            }
        }
    }
}
