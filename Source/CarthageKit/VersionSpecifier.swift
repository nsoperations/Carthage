import Foundation
import Result

/// Describes which versions are acceptable for satisfying a dependency
/// requirement.
public enum VersionSpecifier: Hashable {
    case any
    case atLeast(SemanticVersion)
    case compatibleWith(SemanticVersion)
    case exactly(SemanticVersion)
    case gitReference(String)
    case empty

    /// Determines whether the given version satisfies this version specifier.
    public func isSatisfied(by version: PinnedVersion) -> Bool {
        func withSemanticVersion(_ predicate: (SemanticVersion) -> Bool) -> Bool {
            if let semanticVersion = version.semanticVersion {
                return predicate(semanticVersion)
            } else {
                // Consider non-semantic versions (e.g., branches) to meet every
                // version range requirement
                return true
            }
        }

        switch self {
        case .empty:
            return false
        case .any:
            return withSemanticVersion { !$0.isPreRelease }
        case let .gitReference(hash):
            return version.commitish == hash
        case let .exactly(requirement):
            return withSemanticVersion { $0 == requirement }

        case let .atLeast(requirement):
            return withSemanticVersion { version in
                let versionIsNewer = version >= requirement

                // Only pick a pre-release version if the requirement is also
                // a pre-release of the same version
                let notPreReleaseOrSameComponents =	!version.isPreRelease
                    || (requirement.isPreRelease && version.hasSameNumericComponents(version: requirement))
                return notPreReleaseOrSameComponents && versionIsNewer
            }
        case let .compatibleWith(requirement):
            return withSemanticVersion { version in

                let versionIsNewer = version >= requirement
                let notPreReleaseOrSameComponents =	!version.isPreRelease
                    || (requirement.isPreRelease && version.hasSameNumericComponents(version: requirement))

                // Only pick a pre-release version if the requirement is also
                // a pre-release of the same version
                guard notPreReleaseOrSameComponents else {
                    return false
                }

                // According to SemVer, any 0.x.y release may completely break the
                // exported API, so it's not safe to consider them compatible with one
                // another. Only patch versions are compatible under 0.x, meaning 0.1.1 is
                // compatible with 0.1.2, but not 0.2. This isn't according to the SemVer
                // spec but keeps ~> useful for 0.x.y versions.
                if version.major == 0 {
                    return version.minor == requirement.minor && versionIsNewer
                }

                return version.major == requirement.major && versionIsNewer
            }
        }
    }
}

extension VersionSpecifier: Scannable {
    /// Attempts to parse a VersionSpecifier.
    public static func from(_ scanner: Scanner) -> Result<VersionSpecifier, ScannableError> {
        if scanner.scanString("==", into: nil) {
            return SemanticVersion.from(scanner).map { .exactly($0) }
        } else if scanner.scanString(">=", into: nil) {
            return SemanticVersion.from(scanner).map { .atLeast($0) }
        } else if scanner.scanString("~>", into: nil) {
            return SemanticVersion.from(scanner).map { .compatibleWith($0) }
        } else if scanner.scanString("\"", into: nil) {
            var refName: NSString?
            if !scanner.scanUpTo("\"", into: &refName) || refName == nil {
                return .failure(ScannableError(message: "expected Git reference name", currentLine: scanner.currentLine))
            }

            if !scanner.scanString("\"", into: nil) {
                return .failure(ScannableError(message: "unterminated Git reference name", currentLine: scanner.currentLine))
            }

            return .success(.gitReference(refName! as String))
        } else if scanner.scanString("[]", into: nil) {
            return .success(.empty)
        } else {
            return .success(.any)
        }
    }
}

extension VersionSpecifier: CustomStringConvertible {
    public var description: String {
        switch self {
        case .any:
            return ""
        case .empty:
            return "[]"
        case let .exactly(version):
            return "== \(version)"

        case let .atLeast(version):
            return ">= \(version)"

        case let .compatibleWith(version):
            return "~> \(version)"

        case let .gitReference(refName):
            return "\"\(refName)\""
        }
    }
}

extension VersionSpecifier {

    func intersectionSpecifier(_ other: VersionSpecifier) -> VersionSpecifier {
        return VersionSpecifier.intersection(self, other)
    }

    /// Attempts to determine a version specifier that accurately describes the
    /// intersection between the two given specifiers.
    ///
    /// In other words, any version that satisfies the returned specifier will
    /// satisfy _both_ of the given specifiers.
    static func intersection(_ lhs: VersionSpecifier, _ rhs: VersionSpecifier) -> VersionSpecifier { // swiftlint:disable:this cyclomatic_complexity
        switch (lhs, rhs) {
            // Unfortunately, patterns with a wildcard _ are not considered exhaustive,
        // so do the same thing manually. – swiftlint:disable:this vertical_whitespace_between_cases
        case (.any, .any), (.any, .exactly):
            return rhs
        case (.empty, _), (_, .empty):
            return .empty

        case let (.any, .atLeast(rv)):
            return .atLeast(rv.discardingBuildMetadata)

        case let (.any, .compatibleWith(rv)):
            return .compatibleWith(rv.discardingBuildMetadata)

        case (.exactly, .any):
            return lhs

        case let (.compatibleWith(lv), .any):
            return .compatibleWith(lv.discardingBuildMetadata)

        case let (.atLeast(lv), .any):
            return .atLeast(lv.discardingBuildMetadata)

        case (.gitReference, .any), (.gitReference, .atLeast), (.gitReference, .compatibleWith), (.gitReference, .exactly):
            return lhs

        case (.any, .gitReference), (.atLeast, .gitReference), (.compatibleWith, .gitReference), (.exactly, .gitReference):
            return rhs

        case let (.gitReference(lv), .gitReference(rv)):
            if lv != rv {
                return .empty
            }

            return lhs

        case let (.atLeast(lv), .atLeast(rv)):
            return .atLeast(max(lv.discardingBuildMetadata, rv.discardingBuildMetadata))

        case let (.atLeast(lv), .compatibleWith(rv)):
            return intersection(atLeast: lv.discardingBuildMetadata, compatibleWith: rv.discardingBuildMetadata)

        case let (.atLeast(lv), .exactly(rv)):
            return intersection(atLeast: lv.discardingBuildMetadata, exactly: rv)

        case let (.compatibleWith(lv), .atLeast(rv)):
            return intersection(atLeast: rv.discardingBuildMetadata, compatibleWith: lv.discardingBuildMetadata)

        case let (.compatibleWith(lv), .compatibleWith(rv)):
            if lv.major != rv.major {
                return .empty
            }

            // According to SemVer, any 0.x.y release may completely break the
            // exported API, so it's not safe to consider them compatible with one
            // another. Only patch versions are compatible under 0.x, meaning 0.1.1 is
            // compatible with 0.1.2, but not 0.2. This isn't according to the SemVer
            // spec but keeps ~> useful for 0.x.y versions.
            if lv.major == 0 && rv.major == 0 {
                if lv.minor != rv.minor {
                    return .empty
                }
            }

            return .compatibleWith(max(lv.discardingBuildMetadata, rv.discardingBuildMetadata))

        case let (.compatibleWith(lv), .exactly(rv)):
            return intersection(compatibleWith: lv.discardingBuildMetadata, exactly: rv)

        case let (.exactly(lv), .atLeast(rv)):
            return intersection(atLeast: rv.discardingBuildMetadata, exactly: lv)

        case let (.exactly(lv), .compatibleWith(rv)):
            return intersection(compatibleWith: rv.discardingBuildMetadata, exactly: lv)

        case let (.exactly(lv), .exactly(rv)):
            if lv != rv {
                return .empty
            }

            return lhs
        }
    }

    private static func intersection(atLeast: SemanticVersion, compatibleWith: SemanticVersion) -> VersionSpecifier {
        if atLeast.major > compatibleWith.major {
            return .empty
        } else if atLeast.major < compatibleWith.major {
            return .compatibleWith(compatibleWith)
        } else {
            return .compatibleWith(max(atLeast, compatibleWith))
        }
    }

    private static func intersection(atLeast: SemanticVersion, exactly: SemanticVersion) -> VersionSpecifier {
        if atLeast > exactly {
            return .empty
        }

        return .exactly(exactly)
    }

    private static func intersection(compatibleWith: SemanticVersion, exactly: SemanticVersion) -> VersionSpecifier {
        if exactly.major != compatibleWith.major || compatibleWith > exactly {
            return .empty
        }

        return .exactly(exactly)
    }
}

// Extension for replacing branch/tag or other git references with commit sha references.
extension VersionSpecifier {
    func effectiveSpecifier(for dependency: Dependency, retriever: DependencyRetrieverProtocol) throws -> VersionSpecifier {
        if case let .gitReference(ref) = self, !ref.isGitCommitSha {
            let hash = try retriever.resolvedCommitHash(for: ref, dependency: dependency).get()
            return .gitReference(hash)
        }
        return self
    }
}

extension Sequence where Iterator.Element == VersionSpecifier {

    /// Attempts to determine a version specifier that accurately describes the
    /// intersection between the given specifiers.
    ///
    /// In other words, any version that satisfies the returned specifier will
    /// satisfy _all_ of the given specifiers.
    func intersectionSpecifier() -> VersionSpecifier {
        return self.reduce(.any) { (left: VersionSpecifier, right: VersionSpecifier) -> VersionSpecifier in
            return left.intersectionSpecifier(right)
        }
    }
}
