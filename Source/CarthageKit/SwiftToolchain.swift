import Foundation
import Result
import ReactiveSwift
import ReactiveTask

/// Swift compiler helper methods
final class SwiftToolchain {
    
    /// Emits the currect Swift version
    static func swiftVersion(usingToolchain toolchain: String? = nil) -> SignalProducer<String, SwiftVersionError> {
        return determineSwiftVersion(usingToolchain: toolchain).replayLazily(upTo: 1)
    }
    
    /// Parses output of `swift --version` for the version string.
    static func parseSwiftVersionCommand(output: String?) -> String? {
        guard
            let output = output,
            let regex = try? NSRegularExpression(pattern: "Apple Swift version ([^\\s]+) .*\\((.[^\\)]+)\\)", options: []),
            let match = regex.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output))
            else
        {
            return nil
        }
        
        guard match.numberOfRanges == 3 else { return nil }
        
        let first = output[Range(match.range(at: 1), in: output)!]
        let second = output[Range(match.range(at: 2), in: output)!]
        return "\(first) (\(second))"
    }
    
    /// Attempts to determine the local version of swift
    private static func determineSwiftVersion(usingToolchain toolchain: String?) -> SignalProducer<String, SwiftVersionError> {
        let taskDescription = Task("/usr/bin/env", arguments: compilerVersionArguments(usingToolchain: toolchain))
        
        return taskDescription.launch(standardInput: nil)
            .ignoreTaskData()
            .mapError { _ in SwiftVersionError.unknownLocalSwiftVersion }
            .map { data -> String? in
                return parseSwiftVersionCommand(output: String(data: data, encoding: .utf8))
            }
            .attemptMap { Result($0, failWith: SwiftVersionError.unknownLocalSwiftVersion) }
    }
    
    private static func compilerVersionArguments(usingToolchain toolchain: String?) -> [String] {
        if let toolchain = toolchain {
            return ["xcrun", "--toolchain", toolchain, "swift", "--version"]
        } else {
            return ["xcrun", "swift", "--version"]
        }
    }
}
