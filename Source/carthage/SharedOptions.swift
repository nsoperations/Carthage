//
//  SharedOptions.swift
//  carthage
//
//  Created by Werner Altewischer on 02/09/2019.
//

import Foundation
import Commandant

final class SharedOptions {
    static let netrcOption = Option(key: "use-netrc", defaultValue: false, usage: "use authentication credentials from ~/.netrc file when performing http operations")
}
