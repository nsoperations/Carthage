import Foundation

/// Wrapper around String which uses case-insensitive implementations for Hashable
public struct CaseInsensitiveString: Hashable, LosslessStringConvertible, ExpressibleByStringLiteral {
    public typealias StringLiteralType = String
    
    public let value: String
    private let caseInsensitiveValue: String
    
    public init(stringLiteral: String) {
        self.init(value: stringLiteral)
    }
    
    public init(value: String) {
        self.value = value
        self.caseInsensitiveValue = value.lowercased()
    }
    
    public init?(_ description: String) {
        self.init(value: description)
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.caseInsensitiveValue)
    }
    
    public static func == (lhs: CaseInsensitiveString, rhs: CaseInsensitiveString) -> Bool {
        return lhs.caseInsensitiveValue == rhs.caseInsensitiveValue
    }
    
    public var description: String {
        return value
    }
}
