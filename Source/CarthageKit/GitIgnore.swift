//
//  GitIgnore.swift
//  CarthageKit
//
//  Created by Werner Altewischer on 05/10/2019.
//

import Foundation

/// Class which parses a git ignore file and validates patterns against it
class GitIgnore {
    
    init(ignoreFileURL: URL) {
        
    }
    
    func isIgnored(relativePath: String) -> Bool {
        return false
    }
}
