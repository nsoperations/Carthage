import SPMUtility

/// Defines the current CarthageKit version.
public struct CarthageKitVersion {
    public let value: Version

    public static let current = CarthageKitVersion(value: Version(0, 36, 0, prereleaseIdentifiers: ["beta"], buildMetadataIdentifiers: ["nsoperations"]))
}
