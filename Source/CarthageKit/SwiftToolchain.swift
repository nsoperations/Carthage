import Foundation
import Result
import ReactiveSwift
import ReactiveTask

import struct Foundation.URL

/// Swift compiler helper methods
public final class SwiftToolchain {
    
    private static let cache = Atomic([String?: Result<String, SwiftVersionError>]())
    internal static var swiftVersionRegex: NSRegularExpression = try! NSRegularExpression(pattern: "Apple Swift version ([^\\s]+) .*\\((.[^\\)]+)\\)", options: [])
    
    /// Emits the currect Swift version
    public static func swiftVersion(usingToolchain toolchain: String? = nil) -> SignalProducer<PinnedVersion, SwiftVersionError> {
        return rawSwiftVersion(usingToolchain: toolchain)
            .map { pinnedVersion(from: $0) }
    }

    static func swiftVersion(from commandOutput: String?) -> PinnedVersion? {
        return parseSwiftVersionCommand(output: commandOutput).map { pinnedVersion(from: $0) }
    }

    /// Emits the currect Swift version
    private static func rawSwiftVersion(usingToolchain toolchain: String? = nil) -> SignalProducer<String, SwiftVersionError> {
        return determineSwiftVersion(usingToolchain: toolchain)
    }

    private static func pinnedVersion(from swiftVersionString: String) -> PinnedVersion {
        let index = swiftVersionString.firstIndex { CharacterSet.whitespaces.contains($0) }
        let trimmedVersionString = index.map ({ String(swiftVersionString.prefix(upTo: $0)) }) ?? swiftVersionString
        return PinnedVersion(trimmedVersionString)
    }

    /// Parses output of `swift --version` for the version string.
    private static func parseSwiftVersionCommand(output: String?) -> String? {
        guard
            let output = output,
            let match = SwiftToolchain.swiftVersionRegex.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output))
            else
        {
            return nil
        }

        guard match.numberOfRanges == 3 else { return nil }
        
        let first = output[Range(match.range(at: 1), in: output)!]
        let second = output[Range(match.range(at: 2), in: output)!]
        
        guard let md5 = String(second).md5 else { return nil }
        
        return "\(first)+\(md5)"
    }

    /// Attempts to determine the local version of swift
    private static func determineSwiftVersion(usingToolchain toolchain: String?) -> SignalProducer<String, SwiftVersionError> {
        let result = cache.getValue(toolchain) { toolchain -> Result<String, SwiftVersionError> in
            let taskDescription = Task("/usr/bin/env", arguments: compilerVersionArguments(usingToolchain: toolchain))
            return taskDescription.launch(standardInput: nil)
                .ignoreTaskData()
                .mapError { _ in SwiftVersionError.unknownLocalSwiftVersion }
                .map { data -> String? in
                    return parseSwiftVersionCommand(output: String(data: data, encoding: .utf8))
                }
                .attemptMap { Result($0, failWith: SwiftVersionError.unknownLocalSwiftVersion) }
                .first()!
        }
        return SignalProducer(result: result)
    }

    private static func compilerVersionArguments(usingToolchain toolchain: String?) -> [String] {
        if let toolchain = toolchain {
            return ["xcrun", "--toolchain", toolchain, "swift", "--version"]
        } else {
            return ["xcrun", "swift", "--version"]
        }
    }
}

extension String {
    fileprivate var md5: String? {
        guard let data = self.data(using: .utf8) else {
            return nil
        }
        let digest = MD5Digest()
        digest.update(data: data)
        return digest.finalize().hexString
    }
}
