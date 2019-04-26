//
//  SchemeMatcher.swift
//  CarthageKit
//
//  Created by Werner Altewischer on 26/04/2019.
//

import Foundation
import XCDBLD

public protocol SchemeMatcher {
    func matches(scheme: Scheme) -> Bool
}

public class RegexSchemeMatcher: SchemeMatcher {

    let include: Bool
    let regex: NSRegularExpression

    public init?(pattern: String, include: Bool) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        self.regex = regex
        self.include = include
    }

    public func matches(scheme: Scheme) -> Bool {
        let nsRange = NSRange(scheme.name.startIndex..<scheme.name.endIndex, in: scheme.name)
        let regexMatch = regex.firstMatch(in: scheme.name, options: [], range: nsRange) != nil
        return self.include ? regexMatch : !regexMatch
    }
}

public class LitteralSchemeMatcher: SchemeMatcher {
    let schemeNames: Set<String>

    public init(schemeNames: Set<String>) {
        self.schemeNames = schemeNames
    }

    public func matches(scheme: Scheme) -> Bool {
        return self.schemeNames.contains(scheme.name)
    }
}
