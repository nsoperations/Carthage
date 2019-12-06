//
//  FrameworkOperations.swift
//  Carthage
//
//  Created by Werner Altewischer on 06/12/2019.
//

import Foundation
import Result

public final class FrameworkOperations {
    
    public static func stripFramework(url: URL) -> Result<(), CarthageError> {
        return Frameworks.stripPrivateSymbols(for: url)
    }
}
