import CarthageKit
import Commandant
import Foundation
import Result
import Curry

/// Type that encapsulates the configuration and evaluation of the `version` subcommand.
public struct StripFrameworkCommand: CommandProtocol {
    public struct Options: OptionsProtocol {
        
        public let frameworkPaths: [String]
        
        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            return curry(self.init)
                <*> (mode <| Argument(defaultValue: [], usage: "the frameworks to strip", usageParameter: "framework locations"))
        }
    }
    
    public let verb = "strip-framework"
    public let function = "Strips a framework of its private symbols"

    public func run(_ options: Options) -> Result<(), CarthageError> {
        for path in options.frameworkPaths {
            carthage.printOut("Stripping framework: \(path)")
            let result = FrameworkOperations.stripFramework(url: URL(fileURLWithPath: path))
            if case .failure = result {
                return result
            }
        }
        return .success(())
    }
}
