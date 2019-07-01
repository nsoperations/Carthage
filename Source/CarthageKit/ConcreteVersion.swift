import Foundation
import Result
import BTree

/**
 Wrapper around PinnedVersion/SementicVersion that can be ordered on relevance and avoids multiple invocations of the parsing logic for the Version from a string.

 Semantic versions are first, ordered descending, then versions that do not comply with the semantic structure (*.*.*).
 */
struct ConcreteVersion: Comparable, Hashable, CustomStringConvertible {
    public let pinnedVersion: PinnedVersion
    public let semanticVersion: SemanticVersion?
    private let hash: Int
    private let isUpperBound: Bool

    public init(string: String) {
        self.init(pinnedVersion: PinnedVersion(string))
    }

    public init(pinnedVersion: PinnedVersion) {
        self.pinnedVersion = pinnedVersion
        self.semanticVersion = pinnedVersion.semanticVersion
        self.isUpperBound = false
        self.hash = pinnedVersion.hashValue
    }

    public init(semanticVersion: SemanticVersion, isUpperBound: Bool = false) {
        self.pinnedVersion = PinnedVersion(semanticVersion.description)
        self.semanticVersion = semanticVersion
        self.hash = pinnedVersion.hashValue
        self.isUpperBound = isUpperBound
    }

    private static func compare(lhs: ConcreteVersion, rhs: ConcreteVersion) -> ComparisonResult {
        let leftVersion = lhs.semanticVersion
        let rightVersion = rhs.semanticVersion

        let sameResult = { () -> ComparisonResult in
            lhs.isUpperBound == rhs.isUpperBound ? .orderedSame : lhs.isUpperBound ? .orderedDescending : .orderedAscending
        }

        if let v1 = leftVersion, let v2 = rightVersion {
            return v1 < v2 ? .orderedDescending : v2 < v1 ? .orderedAscending : sameResult()
        } else if leftVersion != nil {
            return .orderedAscending
        } else if rightVersion != nil {
            return .orderedDescending
        }

        let s1 = lhs.pinnedVersion.commitish
        let s2 = rhs.pinnedVersion.commitish
        return s1 < s2 ? .orderedAscending : s2 < s1 ? .orderedDescending : sameResult()
    }

    // All the comparison methods are intentionally defined inline (while the protocol only requires '<' and '==') to increase performance (requires 1 function call instead of 2 function calls this way).
    public static func == (lhs: ConcreteVersion, rhs: ConcreteVersion) -> Bool {
        return compare(lhs: lhs, rhs: rhs) == .orderedSame
    }

    public static func < (lhs: ConcreteVersion, rhs: ConcreteVersion) -> Bool {
        return compare(lhs: lhs, rhs: rhs) == .orderedAscending
    }

    public static func > (lhs: ConcreteVersion, rhs: ConcreteVersion) -> Bool {
        return compare(lhs: lhs, rhs: rhs) == .orderedDescending
    }

    public static func >= (lhs: ConcreteVersion, rhs: ConcreteVersion) -> Bool {
        let comparisonResult = compare(lhs: lhs, rhs: rhs)
        return comparisonResult == .orderedSame || comparisonResult == .orderedDescending
    }

    public static func <= (lhs: ConcreteVersion, rhs: ConcreteVersion) -> Bool {
        let comparisonResult = compare(lhs: lhs, rhs: rhs)
        return comparisonResult == .orderedSame || comparisonResult == .orderedAscending
    }

    public var description: String {
        return pinnedVersion.description
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }
}

/**
 A Dependency with a concrete version.
 */
struct ConcreteVersionedDependency: Hashable {
    public let dependency: Dependency
    public let concreteVersion: ConcreteVersion
    private let hash: Int

    init(dependency: Dependency, concreteVersion: ConcreteVersion) {
        self.dependency = dependency
        self.concreteVersion = concreteVersion
        self.hash = 37 &* dependency.hashValue &+ concreteVersion.hashValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }

    public static func == (lhs: ConcreteVersionedDependency, rhs: ConcreteVersionedDependency) -> Bool {
        return lhs.dependency == rhs.dependency && lhs.concreteVersion == rhs.concreteVersion
    }
}

/**
 A version specification as was defined by a concrete versioned dependency, or nil if it was defined at the top level (i.e. Cartfile)
 */
struct ConcreteVersionSetDefinition {
    public let definingDependency: ConcreteVersionedDependency?
    public let versionSpecifier: VersionSpecifier
}

/**
 Optimized set to keep track of a resolved set of concrete versions which are valid according to the current specifications.

 The set conforms to Sequence to be iteratable and always maintains its natural sorting order.

 Additions/removals/lookups have O(log(N)) time complexity.

 This is intentionally a class instead of a struct to have control over when and how a copy is made of this set.
 */
final class ConcreteVersionSet: Sequence, CustomStringConvertible {
    public typealias Element = ConcreteVersion
    public typealias Iterator = ConcreteVersionSetIterator

    // MARK: - Public properties

    /**
     The collection of definitions that define the versions in this set.
     */
    public private(set) var definitions: [ConcreteVersionSetDefinition]
    public private(set) var effectiveVersionSpecifier: VersionSpecifier?

    public var isPinned: Bool

    // MARK: - Private properties

    private var semanticVersions: SortedSet<ConcreteVersion>
    private var nonSemanticVersions: SortedSet<ConcreteVersion>
    private var preReleaseVersions: SortedSet<ConcreteVersion>

    public var pinnedVersions: [PinnedVersion] {
        var result = [PinnedVersion]()
        result.append(contentsOf: semanticVersions.map { $0.pinnedVersion })
        result.append(contentsOf: preReleaseVersions.map { $0.pinnedVersion })
        result.append(contentsOf: nonSemanticVersions.map { $0.pinnedVersion })
        return result
    }

    // MARK: - Initializers

    public convenience init() {
        self.init(semanticVersions: SortedSet<ConcreteVersion>(),
                  nonSemanticVersions: SortedSet<ConcreteVersion>(),
                  preReleaseVersions: SortedSet<ConcreteVersion>(),
                  definitions: [ConcreteVersionSetDefinition]())
    }

    private init(semanticVersions: SortedSet<ConcreteVersion>,
                 nonSemanticVersions: SortedSet<ConcreteVersion>,
                 preReleaseVersions: SortedSet<ConcreteVersion>,
                 definitions: [ConcreteVersionSetDefinition],
                 effectiveVersionSpecifier: VersionSpecifier? = nil,
                 isPinned: Bool = false) {
        self.semanticVersions = semanticVersions
        self.nonSemanticVersions = nonSemanticVersions
        self.preReleaseVersions = preReleaseVersions
        self.definitions = definitions
        self.effectiveVersionSpecifier = effectiveVersionSpecifier
        self.isPinned = isPinned
    }

    // MARK: - Public methods

    /**
     Creates a copy of this set.
     */
    public var copy: ConcreteVersionSet {
        return ConcreteVersionSet(
            semanticVersions: semanticVersions,
            nonSemanticVersions: nonSemanticVersions,
            preReleaseVersions: preReleaseVersions,
            definitions: definitions,
            effectiveVersionSpecifier: effectiveVersionSpecifier,
            isPinned: isPinned
        )
    }

    /**
     Number of elements in the set.
     */
    public var count: Int {
        return semanticVersions.count + nonSemanticVersions.count + preReleaseVersions.count
    }

    /**
     Whether the set has elements or not.
     */
    public var isEmpty: Bool {
        return semanticVersions.isEmpty && nonSemanticVersions.isEmpty && preReleaseVersions.isEmpty
    }

    /**
     Most relevant version in the set.
     */
    public var first: ConcreteVersion? {
        return self.semanticVersions.first ?? (self.preReleaseVersions.first ?? self.nonSemanticVersions.first)
    }

    /**
     Adds a dependency tree specification to the list of origins for the versions in this set.
     */
    public func addDefinition(_ definition: ConcreteVersionSetDefinition) {
        definitions.append(definition)
    }

    /**
     Inserts the specified version in this set.
     */
    @discardableResult
    public func insert(_ version: ConcreteVersion) -> Bool {
        if let semanticVersion = version.semanticVersion {
            if semanticVersion.isPreRelease {
                return preReleaseVersions.insert(version).inserted
            } else {
                return semanticVersions.insert(version).inserted
            }
        } else {
            return nonSemanticVersions.insert(version).inserted
        }
    }

    /**
     Removes the sepecified version from this set.
     */
    @discardableResult
    public func remove(_ version: ConcreteVersion) -> Bool {
        if let semanticVersion = version.semanticVersion {
            if semanticVersion.isPreRelease {
                return preReleaseVersions.remove(version) != nil
            } else {
                return semanticVersions.remove(version) != nil
            }
        } else {
            return nonSemanticVersions.remove(version) != nil
        }
    }

    /**
     Removes all elements from the set.
     */
    public func removeAll(except version: ConcreteVersion) {
        if let semanticVersion = version.semanticVersion {
            if semanticVersion.isPreRelease {
                semanticVersions.removeAll()
                preReleaseVersions.removeAll(except: version)
            } else {
                preReleaseVersions.removeAll()
                semanticVersions.removeAll(except: version)
            }
            nonSemanticVersions.removeAll()
        } else {
            semanticVersions.removeAll()
            nonSemanticVersions.removeAll(except: version)
            preReleaseVersions.removeAll(except: version)
        }
    }

    /**
     Retains all versions in this set which are compatible with the specified version specifier.
     */
    public func retainVersions(compatibleWith versionSpecifier: VersionSpecifier) {

        let updatedVersionSpecifier: VersionSpecifier = effectiveVersionSpecifier.map { $0.intersectionSpecifier(versionSpecifier) } ?? versionSpecifier
        self.effectiveVersionSpecifier = updatedVersionSpecifier

        // This is an optimization to achieve O(log(N)) time complexity for this method instead of O(N)
        // Should be kept in sync with implementation of VersionSpecifier (better to move it there)
        switch updatedVersionSpecifier {
        case .any:
            preReleaseVersions.removeAll()
        case .empty:
            preReleaseVersions.removeAll()
            semanticVersions.removeAll()
            nonSemanticVersions.removeAll()
        case .gitReference(let hash):
            preReleaseVersions.removeAll()
            semanticVersions.removeAll()
            nonSemanticVersions.removeAll(except: ConcreteVersion(pinnedVersion: PinnedVersion(hash)))
        case .exactly(let requirement):
            let fixedVersion = ConcreteVersion(semanticVersion: requirement)
            semanticVersions.formIntersection(elementsIn: fixedVersion...fixedVersion)
            preReleaseVersions.formIntersection(elementsIn: fixedVersion...fixedVersion)
        case .atLeast(let requirement):
            let lowerBound = ConcreteVersion(semanticVersion: requirement)
            //We have to use the isUpperBound trick, because half open ranges from the left bound are not supported by SortedSet.
            let preReleaseUpperBound = ConcreteVersion(semanticVersion:
                SemanticVersion(requirement.major, requirement.minor, requirement.patch + 1), isUpperBound: true)
            //Bounds are reversed because the versions are sorted in reverse order
            semanticVersions.formPrefix(through: lowerBound)
            preReleaseVersions.formIntersection(elementsIn: preReleaseUpperBound...lowerBound)
        case .compatibleWith(let requirement):
            let lowerBound = ConcreteVersion(semanticVersion: requirement)
            let upperBound = requirement.major > 0 ?
                ConcreteVersion(semanticVersion: SemanticVersion(requirement.major + 1, 0, 0), isUpperBound: true) :
                ConcreteVersion(semanticVersion: SemanticVersion(0, requirement.minor + 1, 0), isUpperBound: true)
            let preReleaseUpperBound = ConcreteVersion(semanticVersion:
                SemanticVersion(requirement.major, requirement.minor, requirement.patch + 1), isUpperBound: true)
            //Bounds are reversed because the versions are sorted in reverse order
            semanticVersions.formIntersection(elementsIn: upperBound...lowerBound)
            preReleaseVersions.formIntersection(elementsIn: preReleaseUpperBound...lowerBound)
        }
    }

    /**
     Returns the conflicting definition for the specified versionSpecifier, or nil if no conflict could be found.
     */
    public func conflictingDefinition(for versionSpecifier: VersionSpecifier) -> ConcreteVersionSetDefinition? {
        return definitions.first {
            $0.versionSpecifier.intersectionSpecifier(versionSpecifier) == .empty
        }
    }

    // MARK: - Sequence implementation

    public func makeIterator() -> Iterator {
        return ConcreteVersionSetIterator(self)
    }

    public struct ConcreteVersionSetIterator: IteratorProtocol {
        // swiftlint:disable next nesting
        typealias Element = ConcreteVersion

        private let versionSet: ConcreteVersionSet
        private var iteratingVersions = true
        private var iteratingPreReleaseVersions = false
        private var currentIterator: SortedSet<ConcreteVersion>.Iterator

        fileprivate init(_ versionSet: ConcreteVersionSet) {
            self.versionSet = versionSet
            self.currentIterator = versionSet.semanticVersions.makeIterator()
        }

        public mutating func next() -> Element? {
            var ret = currentIterator.next()
            if ret == nil && iteratingVersions {
                iteratingVersions = false
                iteratingPreReleaseVersions = true
                currentIterator = versionSet.preReleaseVersions.makeIterator()
                ret = currentIterator.next()
            }
            if ret == nil && iteratingPreReleaseVersions {
                iteratingPreReleaseVersions = false
                currentIterator = versionSet.nonSemanticVersions.makeIterator()
                ret = currentIterator.next()
            }
            return ret
        }
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        var s = "["
        var first = true
        for concreteVersion in self {
            if !first {
                s += ", "
            }
            s += concreteVersion.description
            first = false
        }
        s += "]"
        return s
    }
}

extension SortedSet {
    fileprivate mutating func removeAll(except element: Element) {
        self.removeAll()
        self.insert(element)
    }

    fileprivate mutating func formPrefix(through upperBound: Element) {
        self = self.prefix(through: upperBound)
    }
}
