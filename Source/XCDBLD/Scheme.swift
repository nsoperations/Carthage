/// Represents a scheme to be built
public struct Scheme: Hashable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}

extension Scheme: CustomStringConvertible {
    public var description: String {
        return name
    }
}
