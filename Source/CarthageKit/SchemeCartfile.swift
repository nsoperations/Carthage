import Foundation
import Result

public struct SchemeCartfile {

    public let schemes: Set<String>

    public init<T: Sequence>(schemes: T) where T.Element == String {
        self.schemes = Set(schemes)
    }

    public var matcher: SchemeMatcher {
        return LitteralSchemeMatcher(schemeNames: schemes)
    }
}

extension SchemeCartfile: CartfileProtocol {

    public static var relativePath: String {
        return Constants.Project.schemesCartfilePath
    }

    public static func from(string: String) -> Result<SchemeCartfile, CarthageError> {
        var schemes = Set<String>()
        let lines = string.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix(ResolvedCartfile.commentIndicator) {
                continue
            }
            let scheme = line.trimmingCharacters(in: .whitespaces)

            if !scheme.isEmpty {
                schemes.insert(scheme)
            }
        }
        return .success(SchemeCartfile(schemes: schemes))
    }
}

extension SchemeCartfile: CustomStringConvertible {
    public var description: String {
        return schemes
            .sorted { $0 < $1 }
            .joined(separator: "\n")
            .appending("\n")
    }
}
