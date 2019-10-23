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
    
    var copy: GitIgnore {
        let copy = GitIgnore(parent: self.parent)
        copy.negatedPatterns = self.negatedPatterns
        copy.patterns = self.patterns
        return copy
    }
    
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

    private static func normalizedPattern(_ pattern: String) -> (pattern: String, negated: Bool, onlyDirectories: Bool)? {

        guard !pattern.isEmpty else {
            return nil
        }

        var isNegated = false
        var onlyDirectories = false

        var startIndex = pattern.startIndex
        var endIndex = pattern.endIndex
        var lastSpace = false

        // Chop trailing spaces
        for c in pattern.reversed() {
            if c == " " {
                lastSpace = true
                endIndex = pattern.index(before: endIndex)
                continue
            } else if c == "\\" && lastSpace {
                // escaped space, add it back
                endIndex = pattern.index(after: endIndex)
            } else if c == "/" {
                onlyDirectories = true
                endIndex = pattern.index(before: endIndex)
            }
            break
        }

        let firstCharacter = pattern[startIndex]
        var escaped = false
        if firstCharacter == "\\" {
            escaped = true
            // Check whether this is an escape for the next character
            let nextIndex = pattern.index(after: startIndex)
            if nextIndex < endIndex {
                let nextCharacter = pattern[pattern.index(after: startIndex)]
                switch nextCharacter {
                case "!", "#":
                    startIndex = nextIndex
                default:
                    break
                }
            }
        } else if firstCharacter == "#" {
            // Comment
            return nil
        } else if firstCharacter == "!" {
            // Negated pattern
            isNegated = true
            startIndex = pattern.index(after: startIndex)
        }
        if !escaped && startIndex < endIndex && pattern[startIndex] == "/" {
            // Chop leading slash
            startIndex = pattern.index(after: startIndex)
        }

        guard startIndex < endIndex else {
            return nil
        }

        let patternString = pattern[startIndex..<endIndex]
        let normalizedString: String

        if !patternString.contains("/") {
            // No slash is considered to be a match in all directories
            normalizedString = "**/" + patternString
        } else {
            normalizedString = String(patternString)
        }

        return (normalizedString, isNegated, onlyDirectories)
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
