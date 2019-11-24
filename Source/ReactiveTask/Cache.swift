import Foundation
import ReactiveSwift

public protocol CacheStorage {
    associatedtype Key: Hashable
    associatedtype Value
    subscript(_ key: Key) -> Value? { get set }
    mutating func clear()
    mutating func popFirst() -> (key: Key, value: Value)?
}

extension Dictionary: CacheStorage {
    public mutating func clear() {
        self.removeAll()
    }
}

extension Atomic where Value: CacheStorage {
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
    
    public func popFirst() -> (key: Value.Key, value: Value.Value)? {
        return self.modify { cache -> (key: Value.Key, value: Value.Value)? in
            return cache.popFirst()
        }
    }
    
    public func clear() {
        self.modify { cache -> Void in
            cache.clear()
        }
    }
}
