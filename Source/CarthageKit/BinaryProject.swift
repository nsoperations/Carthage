import Foundation
import Result

public struct BinaryProjectFile: Equatable {
    let url: URL
    let configuration: String?
    let swiftVersion: PinnedVersion?

    init(url: URL, configuration: String?, swiftVersion: PinnedVersion?) {
        self.url = url
        self.configuration = configuration
        self.swiftVersion = swiftVersion
    }
}

/// Represents a binary dependency
public struct BinaryProject: Equatable {

    private let definitions: [PinnedVersion: [BinaryProjectFile]]

    public init(definitions: [PinnedVersion: [BinaryProjectFile]]) {
        self.definitions = definitions
    }

    public init(urls: [PinnedVersion: URL]) {
        self.definitions = urls.reduce(into: [PinnedVersion: [BinaryProjectFile]](), { dict, entry in
            dict[entry.key] = [BinaryProjectFile(url: entry.value, configuration: nil, swiftVersion: nil)]
        })
    }

    public var versions: [PinnedVersion] {
        return Array(definitions.keys)
    }

    public func binaryURL(for version: PinnedVersion, configuration: String, swiftVersion: PinnedVersion) -> URL? {
        guard let binaryProjectFiles = definitions[version] else {
            return nil
        }

        return binaryProjectFiles.first(where: { binaryProjectFile -> Bool in
            (binaryProjectFile.configuration.map{ $0 == configuration } ?? true) && (binaryProjectFile.swiftVersion.map { $0 == swiftVersion } ?? true)
        }).map {
            $0.url
        }
    }

    public static func from(jsonData: Data) -> Result<BinaryProject, BinaryJSONError> {
        do {
            let result = try parse(jsonData: jsonData)
            return .success(result)
        } catch let error as BinaryJSONError {
            return .failure(error)
        } catch {
            return .failure(BinaryJSONError.invalidJSON(error.localizedDescription))
        }
    }

    private static func parse(jsonData: Data) throws -> BinaryProject {

        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw BinaryJSONError.invalidJSON("Root level JSON object should be a dictionary")
        }

        var definitions = [PinnedVersion: [BinaryProjectFile]]()
        for (key, value) in json {
            let pinnedVersion: PinnedVersion
            switch SemanticVersion.from(Scanner(string: key)) {
            case .success:
                pinnedVersion = PinnedVersion(key)
            case let .failure(error):
                throw BinaryJSONError.invalidVersion(error)
            }
            if let stringValue = value as? String {
                let binaryURL = try parseURL(stringValue: stringValue)
                let projectFile = BinaryProjectFile(url: binaryURL, configuration: nil, swiftVersion: nil)
                definitions[pinnedVersion, default: [BinaryProjectFile]()].append(projectFile)

            } else if let dictValues = value as? [[String: String]] {
                for dictValue in dictValues {
                    var swiftVersion: PinnedVersion?
                    guard let urlString = dictValue["url"] else {
                        throw BinaryJSONError.invalidJSON("No url property found for version: \(pinnedVersion)")
                    }

                    let binaryURL = try parseURL(stringValue: urlString)
                    let configuration = dictValue["configuration"]
                    if let versionString = dictValue["swiftVersion"] {
                        swiftVersion = PinnedVersion(versionString)
                    }

                    let projectFile = BinaryProjectFile(url: binaryURL, configuration: configuration, swiftVersion: swiftVersion)
                    definitions[pinnedVersion, default: [BinaryProjectFile]()].append(projectFile)
                }
            } else {
                throw BinaryJSONError.invalidJSON("Value should either be a string or a dictionary containing the properties 'url', 'configuration' and 'swiftVersion'")
            }
        }
        return BinaryProject(definitions: definitions)
    }

    private static func parseURL(stringValue: String) throws -> URL {
        guard let binaryURL = URL(string: stringValue) else {
            throw BinaryJSONError.invalidURL(stringValue)
        }
        guard binaryURL.scheme == "file" || binaryURL.scheme == "https" else {
            throw BinaryJSONError.nonHTTPSURL(binaryURL)
        }
        return binaryURL
    }
}
