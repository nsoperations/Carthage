import Foundation
import Result

/// A struct representing a semver version.
public struct SemanticVersion: Hashable {

    /// The major version.
    public let major: Int

    /// The minor version.
    public let minor: Int

    /// The patch version.
    public let patch: Int

    /// The pre-release identifier.
    public let prereleaseIdentifiers: [String]

    /// The build metadata.
    public let buildMetadataIdentifiers: [String]

    /// Create a version object.
    public init(
        _ major: Int,
        _ minor: Int,
        _ patch: Int,
        prereleaseIdentifiers: [String] = [],
        buildMetadataIdentifiers: [String] = []
        ) {
        precondition(major >= 0 && minor >= 0 && patch >= 0, "Negative versioning is invalid.")
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadataIdentifiers = buildMetadataIdentifiers
    }
}

extension SemanticVersion: Comparable {

    func isEqualWithoutPrerelease(_ other: SemanticVersion) -> Bool {
        return major == other.major && minor == other.minor && patch == other.patch
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let lhsComparators = [lhs.major, lhs.minor, lhs.patch]
        let rhsComparators = [rhs.major, rhs.minor, rhs.patch]

        if lhsComparators != rhsComparators {
            return lhsComparators.lexicographicallyPrecedes(rhsComparators)
        }

        guard lhs.prereleaseIdentifiers.count > 0 else {
            return false // Non-prerelease lhs >= potentially prerelease rhs
        }

        guard rhs.prereleaseIdentifiers.count > 0 else {
            return true // Prerelease lhs < non-prerelease rhs
        }

        let zippedIdentifiers = zip(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers)
        for (lhsPrereleaseIdentifier, rhsPrereleaseIdentifier) in zippedIdentifiers {
            if lhsPrereleaseIdentifier == rhsPrereleaseIdentifier {
                continue
            }

            let typedLhsIdentifier: Any = Int(lhsPrereleaseIdentifier) ?? lhsPrereleaseIdentifier
            let typedRhsIdentifier: Any = Int(rhsPrereleaseIdentifier) ?? rhsPrereleaseIdentifier

            switch (typedLhsIdentifier, typedRhsIdentifier) {
            case let (int1 as Int, int2 as Int): return int1 < int2
            case let (string1 as String, string2 as String): return string1 < string2
            case (is Int, is String): return true // Int prereleases < String prereleases
            case (is String, is Int): return false
            default:
                return false
            }
        }

        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }
}

extension SemanticVersion: CustomStringConvertible {
    public var description: String {
        var base = "\(major).\(minor).\(patch)"
        if !prereleaseIdentifiers.isEmpty {
            base += "-" + prereleaseIdentifiers.joined(separator: ".")
        }
        if !buildMetadataIdentifiers.isEmpty {
            base += "+" + buildMetadataIdentifiers.joined(separator: ".")
        }
        return base
    }
}

public extension SemanticVersion {

    /// Create a version object from string.
    ///
    /// - Parameters:
    ///   - string: The string to parse.
    init?(string: String) {
        let prereleaseStartIndex = string.index(of: "-")
        let metadataStartIndex = string.index(of: "+")

        let requiredEndIndex = prereleaseStartIndex ?? metadataStartIndex ?? string.endIndex
        let requiredCharacters = string.prefix(upTo: requiredEndIndex)
        let requiredComponents = requiredCharacters
            .split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init).compactMap({ Int($0) }).filter({ $0 >= 0 })

        guard requiredComponents.count == 3 else { return nil }

        self.major = requiredComponents[0]
        self.minor = requiredComponents[1]
        self.patch = requiredComponents[2]

        func identifiers(start: String.Index?, end: String.Index) -> [String] {
            guard let start = start else { return [] }
            let identifiers = string[string.index(after: start)..<end]
            return identifiers.split(separator: ".").map(String.init)
        }

        self.prereleaseIdentifiers = identifiers(
            start: prereleaseStartIndex,
            end: metadataStartIndex ?? string.endIndex)
        self.buildMetadataIdentifiers = identifiers(
            start: metadataStartIndex,
            end: string.endIndex)
    }
}

extension SemanticVersion: ExpressibleByStringLiteral {

    public init(stringLiteral value: String) {
        guard let version = SemanticVersion(string: value) else {
            fatalError("\(value) is not a valid version")
        }
        self = version
    }

    public init(extendedGraphemeClusterLiteral value: String) {
        self.init(stringLiteral: value)
    }

    public init(unicodeScalarLiteral value: String) {
        self.init(stringLiteral: value)
    }
}

extension SemanticVersion {
    init(_ version: SemanticVersion) {
        self.init(
            version.major, version.minor, version.patch,
            prereleaseIdentifiers: version.prereleaseIdentifiers,
            buildMetadataIdentifiers: version.buildMetadataIdentifiers
        )
    }
}

extension SemanticVersion: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)

        guard let version = SemanticVersion(string: string) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid version string \(string)"))
        }

        self.init(version)
    }
}

// MARK: - Range operations

extension ClosedRange where Bound == SemanticVersion {
    /// Marked as unavailable because we have custom rules for contains.
    public func contains(_ element: SemanticVersion) -> Bool {
        // Unfortunately, we can't use unavailable here.
        fatalError("contains(_:) is unavailable, use contains(version:)")
    }
}

// Disabled because compiler hits an assertion https://bugs.swift.org/browse/SR-5014
#if false
extension CountableRange where Bound == SemanticVersion {
    /// Marked as unavailable because we have custom rules for contains.
    public func contains(_ element: SemanticVersion) -> Bool {
        // Unfortunately, we can't use unavailable here.
        fatalError("contains(_:) is unavailable, use contains(version:)")
    }
}
#endif

extension Range where Bound == SemanticVersion {
    /// Marked as unavailable because we have custom rules for contains.
    public func contains(_ element: SemanticVersion) -> Bool {
        // Unfortunately, we can't use unavailable here.
        fatalError("contains(_:) is unavailable, use contains(version:)")
    }
}

extension Range where Bound == SemanticVersion {

    public func contains(version: SemanticVersion) -> Bool {
        // Special cases if version contains prerelease identifiers.
        if !version.prereleaseIdentifiers.isEmpty {
            // If the ranage does not contain prerelease identifiers, return false.
            if lowerBound.prereleaseIdentifiers.isEmpty && upperBound.prereleaseIdentifiers.isEmpty {
                return false
            }

            // At this point, one of the bounds contains prerelease identifiers.
            //
            // Reject 2.0.0-alpha when upper bound is 2.0.0.
            if upperBound.prereleaseIdentifiers.isEmpty && upperBound.isEqualWithoutPrerelease(version) {
                return false
            }
        }

        // Otherwise, apply normal contains rules.
        return version >= lowerBound && version < upperBound
    }
}

extension SemanticVersion {
    public var isPreRelease: Bool {
        return !prereleaseIdentifiers.isEmpty
    }

    public var discardingBuildMetadata: SemanticVersion {
        return SemanticVersion(major, minor, patch, prereleaseIdentifiers: prereleaseIdentifiers)
    }

    public func hasSameNumericComponents(version: SemanticVersion) -> Bool {
        return major == version.major
            && minor == version.minor
            && patch == version.patch
    }
}

extension SemanticVersion {
    static func from(commitish: String) -> Result<SemanticVersion, ScannableError> {
        let scanner = Scanner(string: commitish)

        // Skip leading characters, like "v" or "version-" or anything like
        // that.
        scanner.scanUpToCharacters(from: versionCharacterSet, into: nil)

        return self.from(scanner).flatMap { version in
            if scanner.isAtEnd {
                return .success(version)
            } else {
                return .failure(ScannableError(message: "syntax of version \"\(version)\" is unsupported", currentLine: scanner.currentLine))
            }
        }
    }

    /// Set of valid digts for SemVer versions
    /// - note: Please use this instead of `CharacterSet.decimalDigits`, as
    /// `decimalDigits` include more characters that are not contemplated in
    /// the SemVer spects (e.g. `FULLWIDTH` version of digits, like `４`)
    fileprivate static let semVerDecimalDigits = CharacterSet(charactersIn: "0123456789")

    /// Set of valid characters for SemVer major.minor.patch section
    fileprivate static let versionCharacterSet = CharacterSet(charactersIn: ".")
        .union(SemanticVersion.semVerDecimalDigits)

    fileprivate static let asciiAlphabeth = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvxyzABCDEFGHIJKLMNOPQRSTUVXYZ"
    )

    /// Set of valid character for SemVer build metadata section
    fileprivate static let invalidBuildMetadataCharacters = asciiAlphabeth
        .union(SemanticVersion.semVerDecimalDigits)
        .union(CharacterSet(charactersIn: "-"))
        .inverted

    /// Separator of pre-release components
    fileprivate static let preReleaseComponentsSeparator = "."
}

extension SemanticVersion: Scannable {
    /// Attempts to parse a semantic version from a human-readable string of the
    /// form "a.b.c" from a string scanner.
    public static func from(_ scanner: Scanner) -> Result<SemanticVersion, ScannableError> {
        var versionBuffer: NSString?
        guard scanner.scanCharacters(from: versionCharacterSet, into: &versionBuffer),
            let version = versionBuffer as String? else {
                return .failure(ScannableError(message: "expected version", currentLine: scanner.currentLine))
        }

        let components = version
            .split(omittingEmptySubsequences: false) { $0 == "." }
        guard !components.isEmpty else {
            return .failure(ScannableError(message: "expected version", currentLine: scanner.currentLine))
        }
        guard components.count <= 3 else {
            return .failure(ScannableError(message: "found more than 3 dot-separated components in version", currentLine: scanner.currentLine))
        }

        func parseVersion(at index: Int) -> Int? {
            return components.count > index ? Int(components[index]) : nil
        }

        guard let major = parseVersion(at: 0) else {
            return .failure(ScannableError(message: "expected major version number", currentLine: scanner.currentLine))
        }

        guard let minor = parseVersion(at: 1) else {
            return .failure(ScannableError(message: "expected minor version number", currentLine: scanner.currentLine))
        }

        let hasPatchComponent = components.count > 2
        let patch = parseVersion(at: 2)
        guard !hasPatchComponent || patch != nil else {
            return .failure(ScannableError(message: "invalid patch version", currentLine: scanner.currentLine))
        }

        let preRelease = scanner.scanStringWithPrefix("-", until: "+")
        let buildMetadata = scanner.scanStringWithPrefix("+", until: "")
        guard scanner.isAtEnd else {
            return .failure(ScannableError(message: "expected valid version", currentLine: scanner.currentLine))
        }

        if
            let buildMetadata = buildMetadata,
            let error = SemanticVersion.validateBuildMetadata(buildMetadata, fullVersion: version)
        {
            return .failure(error)
        }

        if
            let preRelease = preRelease,
            let error = SemanticVersion.validatePreRelease(preRelease, fullVersion: version)
        {
            return .failure(error)
        }

        return .success(self.init(
            major,
            minor,
            patch ?? 0,
            prereleaseIdentifiers: preRelease?.split(separator: ".").map(String.init) ?? [],
            buildMetadataIdentifiers: buildMetadata?.split(separator: ".").map(String.init) ?? []
        ))
    }

    /// Checks validity of a build metadata string and returns an error if not valid
    static private func validateBuildMetadata(_ buildMetadata: String, fullVersion: String) -> ScannableError? {
        guard !buildMetadata.isEmpty else {
            return ScannableError(message: "Build metadata is empty after '+', in \"\(fullVersion)\"")
        }
        guard !buildMetadata.containsAny(invalidBuildMetadataCharacters) else {
            return ScannableError(message: "Build metadata contains invalid characters, in \"\(fullVersion)\"")
        }
        return nil
    }

    /// Checks validity of a pre-release string and returns an error if not valid
    static private func validatePreRelease(_ preRelease: String, fullVersion: String) -> ScannableError? {
        guard !preRelease.isEmpty else {
            return ScannableError(message: "Pre-release is empty after '-', in \"\(fullVersion)\"")
        }

        let components = preRelease.components(separatedBy: preReleaseComponentsSeparator)
        guard components.first(where: { $0.containsAny(invalidBuildMetadataCharacters) }) == nil else {
            return ScannableError(message: "Pre-release contains invalid characters, in \"\(fullVersion)\"")
        }

        guard components.first(where: { $0.isEmpty }) == nil else {
            return ScannableError(message: "Pre-release component is empty, in \"\(fullVersion)\"")
        }

        // swiftlint:disable:next first_where
        guard components
            .filter({ !$0.containsAny(SemanticVersion.semVerDecimalDigits.inverted) && $0 != "0" })
            // MUST NOT include leading zeros
            .first(where: { $0.hasPrefix("0") }) == nil else {
                return ScannableError(message: "Pre-release contains leading zero component, in \"\(fullVersion)\"")
        }
        return nil
    }
}

extension Scanner {

    /// Scans a string that is supposed to start with the given prefix, until the given
    /// string is encountered.
    /// - returns: the scanned string without the prefix. If the string does not start with the prefix,
    /// or the scanner is at the end, it returns `nil` without advancing the scanner.
    fileprivate func scanStringWithPrefix(_ prefix: Character, until: String) -> String? {
        guard !self.isAtEnd, self.remainingSubstring?.first == prefix else { return nil }

        var buffer: NSString?
        self.scanUpTo(until, into: &buffer)
        guard let stringWithPrefix = buffer as String?, stringWithPrefix.first == prefix else {
            return nil
        }

        return String(stringWithPrefix.dropFirst())
    }
}
