/// Defines the current CarthageKit version.
public struct CarthageKitVersion {
    public let value: SemanticVersion
    public static let current = CarthageKitVersion(value: SemanticVersion(0, 39, 2, prereleaseIdentifiers: ["beta"], buildMetadataIdentifiers: ["nsoperations"]))
}
