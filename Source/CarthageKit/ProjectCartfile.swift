import Foundation
import Result
import Yams

public struct ProjectCartfile: Codable {
    
    

    
}

extension ProjectCartfile: CartfileProtocol {

    public static var relativePath: String {
        return Constants.Project.projectCartfilePath
    }

    public static func from(string: String) -> Result<ProjectCartfile, CarthageError> {
        
        //let decoder = YAMLDecoder()
        //let decoded = try decoder.decode(S.self, from: encodedYAML)
        //s.p == decoded.p
        
        return .success(ProjectCartfile())
    }
}

extension ProjectCartfile: CustomStringConvertible {
    public var description: String {
        return ""
    }
}
