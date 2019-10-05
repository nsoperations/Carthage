//
//  GitIgnore.swift
//  CarthageKit
//
//  Created by Werner Altewischer on 05/10/2019.
//

import Foundation
import wildmatch

/// Class which parses a git ignore file and validates patterns against it
class GitIgnore {
    
    private var negatedPatterns = [Pattern]()
    private var patterns = [Pattern]()
    
    init() {
    }
    
    func addPatterns(from file: URL) throws {
        let string = try String(contentsOf: file, encoding: .utf8)
        addPatterns(from: string)
    }
    
    func addPatterns(from string: String) {
        let components = string.components(separatedBy: .newlines)
        
        for component in components {
            let trimmedComponent = component.trimmingCharacters(in: .whitespaces)
            if !trimmedComponent.hasPrefix("#") {
                addPattern(trimmedComponent)
            }
        }
    }
    
    func addPattern(_ pattern: String) {
        let isNegated: Bool
        let patternString: String
        
        if pattern.hasPrefix("!") {
            // Negated pattern
            isNegated = true
            patternString = String(pattern.substring(from: 1))
        } else {
            isNegated = false
            patternString = pattern
        }
        
        if let pattern = Pattern(string: patternString) {
            if isNegated {
                negatedPatterns.append(pattern)
            } else {
                patterns.append(pattern)
            }
        }
    }
    
    func isIgnored(relativePath: String) -> Bool {
        return !negatedPatterns.contains(where: { $0.matches(relativePath: relativePath) }) &&
            patterns.contains(where: { $0.matches(relativePath: relativePath) })
    }
}

private class Pattern {
    
    private let regex: NSRegularExpression
    
    init?(string: String) {
        guard let regex = Pattern.regex(from: string) else {
            return nil
        }
        self.regex = regex
    }
    
    static func regex(from string: String) -> NSRegularExpression? {
        
        // TODO: handle escaping
        
        return nil
    }
    
    func matches(relativePath: String) -> Bool {
        let fullRange = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
        guard let match = self.regex.firstMatch(in: relativePath, options: [.anchored], range: fullRange) else {
            return false
        }
        return match.range == fullRange
    }
    
}
