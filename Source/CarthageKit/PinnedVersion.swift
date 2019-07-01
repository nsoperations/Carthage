import Foundation
import Result

/// An immutable version that a project can be pinned to.
public struct PinnedVersion: Hashable {
    /// The commit SHA, or name of the tag, to pin to.
    public let commitish: String
    public var semanticVersion: SemanticVersion? {
        return _semanticVersion.value
    }
    public var isSemantic: Bool {
        return self.semanticVersion != nil
    }

    private let _semanticVersion: LazyValue<SemanticVersion?>

    public init(_ commitish: String) {
        self.commitish = commitish
        self._semanticVersion = LazyValue<SemanticVersion?> {
            return SemanticVersion.from(commitish: commitish).value
        }
    }

    public static func == (lhs: PinnedVersion, rhs: PinnedVersion) -> Bool {
        return lhs.commitish == rhs.commitish
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.commitish)
    }
}

extension PinnedVersion: Scannable {
    public static func from(_ scanner: Scanner) -> Result<PinnedVersion, ScannableError> {
        if !scanner.scanString("\"", into: nil) {
            return .failure(ScannableError(message: "expected pinned version", currentLine: scanner.currentLine))
        }

        var commitish: NSString?
        if !scanner.scanUpTo("\"", into: &commitish) || commitish == nil {
            return .failure(ScannableError(message: "empty pinned version", currentLine: scanner.currentLine))
        }

        if !scanner.scanString("\"", into: nil) {
            return .failure(ScannableError(message: "unterminated pinned version", currentLine: scanner.currentLine))
        }

        return .success(self.init(commitish! as String))
    }
}

extension PinnedVersion: CustomStringConvertible {
    public var description: String {
        return self.commitish
    }
}
