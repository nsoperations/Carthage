import CarthageKit
import Commandant
import Foundation
import Result
import Curry

/// Type that encapsulates the configuration and evaluation of the `version` subcommand.
public struct SwiftVersionCommand: CommandProtocol {
    
    public struct Options: OptionsProtocol {
        
        public let toolchain: String?
        
        public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
            
            let option1 = Option<String?>(key: "toolchain", defaultValue: nil, usage: "the toolchain to build with")
            
            return curry(self.init)
                <*> mode <| option1
        }
    }
    
    public let verb = "swift-version"
    public let function = "Display the current Swift version in use by carthage as parsed to cross-reference compatibility for binaries"
    
    public func run(_ options: Options) -> Result<(), CarthageError> {
        switch SwiftToolchain.swiftVersion(usingToolchain: options.toolchain).first()! {
        case .success(let pinnedVersion):
            carthage.println(pinnedVersion)
            return .success(())
        case .failure(let error):
            let carthageError = CarthageError.internalError(description: error.description)
            return .failure(carthageError)
        }
    }
}

