import Foundation
import Result
import Yams
import XCDBLD

public struct ProjectCartfile {
    public let schemeConfigurations: [String: SchemeConfiguration]
}

public struct SchemeConfiguration: Codable {
    public let project: String
    public let sdks: [SDK]
    
    public func projectLocator(in directoryURL: URL) -> ProjectLocator? {
        let fullURL = directoryURL.appendingPathComponent(project)
        return ProjectLocator.from(url: fullURL)
    }
}

extension ProjectCartfile: CartfileProtocol {

    public static var relativePath: String {
        return Constants.Project.projectCartfilePath
    }

    public static func from(string: String) -> Result<ProjectCartfile, CarthageError> {
        
        //let decoder = YAMLDecoder()
        //let decoded = try decoder.decode(S.self, from: encodedYAML)
        //s.p == decoded.p
        
        return Result(catching: { () -> ProjectCartfile in
            do {
                let decoder = YAMLDecoder()
                let dict = try decoder.decode([String: SchemeConfiguration].self, from: string)
                return ProjectCartfile(schemeConfigurations: dict)
            } catch {
                if isEmptyYML(string) {
                    return ProjectCartfile(schemeConfigurations: [:])
                }
                
                throw CarthageError.parseError(
                    description: "Could not decode Cartfile.project: \(error)"
                )
            }
        })
    }
    
    private static func isEmptyYML(_ string: String) -> Bool {
        let components = string.components(separatedBy: .newlines)
        for component in components {
            let trimmedLine = component.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }
            return false
        }
        return true
    }
}

extension ProjectCartfile: CustomStringConvertible {
    public var description: String {
        let encoder = YAMLEncoder()
        do {
            return try encoder.encode(self.schemeConfigurations)
        } catch {
            return String(describing: error)
        }
    }
}
