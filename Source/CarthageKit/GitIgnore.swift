//
//  GitIgnore.swift
//  CarthageKit
//
//  Created by Werner Altewischer on 05/10/2019.
//

import Foundation
import wildmatch

/// Class which parses a git ignore file and validates patterns against it
struct GitIgnore {
    
    private var negatedPatterns = [Pattern]()
    private var patterns = [Pattern]()
    
    init() {
    }
    
    mutating func addPatterns(from file: URL) throws {
        let string = try String(contentsOf: file, encoding: .utf8)
        addPatterns(from: string)
    }
    
    mutating func addPatterns(from string: String) {
        let components = string.components(separatedBy: .newlines)
        
        for component in components {
            let trimmedComponent = component.trimmingCharacters(in: .whitespaces)
            if !trimmedComponent.hasPrefix("#") && !trimmedComponent.isEmpty {
                addPattern(trimmedComponent)
            }
        }
    }
    
    mutating func addPattern(_ pattern: String) {
        let (patternString, isNegated) = normalizedPattern(pattern)
        if let pattern = Pattern(string: patternString) {
            if isNegated {
                negatedPatterns.append(pattern)
            } else {
                patterns.append(pattern)
            }
        }
    }
    
    private func normalizedPattern(_ pattern: String) -> (pattern: String, negated: Bool) {
        var isNegated = false
        var patternString = pattern
        
        // Normalize the patternString such that it can be used for a wild card match
        if patternString.hasPrefix("!") {
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
        
        return (patternString, isNegated)
    }
    
    func matches(relativePath: String) -> Bool {
        return !negatedPatterns.contains(where: { $0.matches(relativePath: relativePath) }) &&
            patterns.contains(where: { $0.matches(relativePath: relativePath) })
    }
}

private struct Pattern {
    
    private let rawPattern: [CChar]
    
    init?(string: String) {
        guard let cString = string.cString(using: .utf8) else {
            return nil
        }
        self.rawPattern = cString
    }
    
    func matches(relativePath: String) -> Bool {
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
