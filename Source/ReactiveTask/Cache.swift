import Foundation
import ReactiveSwift

public protocol Cache {
    associatedtype Key: Hashable
    associatedtype Value
    subscript(_ key: Key) -> Value? { get set }
}

extension Dictionary: Cache {
    
}

extension Atomic where Value: Cache {
    public subscript(_ key: Value.Key) -> Value.Value? {
        get {
            return self.withValue { map -> Value.Value? in
                return map[key]
            }
        }
        
        set {
            self.modify { map in
                map[key] = newValue
            }
        }
    }
    
    public func getValue(_ key: Value.Key, default constructor: (Value.Key) -> Value.Value) -> Value.Value {
        return self.modify { cache -> Value.Value in
            
            if let existingValue = cache[key] {
                return existingValue
            }
            
            let value = constructor(key)
            cache[key] = value
            return value
        }
    }
}
