import Foundation

/// An atomic variable.
public final class ObservableAtomic<Value> {
    private let condition = NSCondition()
    private var _value: Value
    
    /// Atomically get or set the value of the variable.
    public var value: Value {
        get {
            return withValue { $0 }
        }
        
        set(newValue) {
            swap(newValue)
        }
    }
    
    /// Initialize the variable with the given initial value.
    ///
    /// - parameters:
    ///   - value: Initial value for `self`.
    public init(_ value: Value) {
        _value = value
    }
    
    /// Atomically modifies the variable.
    ///
    /// - parameters:
    ///   - action: A closure that takes the current value.
    ///
    /// - returns: The result of the action.
    @discardableResult
    public func modify<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        return try action(&_value)
    }
    
    /// Atomically perform an arbitrary action using the current value of the
    /// variable.
    ///
    /// - parameters:
    ///   - action: A closure that takes the current value.
    ///
    /// - returns: The result of the action.
    @discardableResult
    public func withValue<Result>(_ action: (Value) throws -> Result) rethrows -> Result {
        condition.lock()
        defer { condition.unlock() }
        
        return try action(_value)
    }
    
    /// Atomically replace the contents of the variable.
    ///
    /// - parameters:
    ///   - newValue: A new value for the variable.
    ///
    /// - returns: The old value.
    @discardableResult
    public func swap(_ newValue: Value) -> Value {
        return modify { (value: inout Value) in
            let oldValue = value
            value = newValue
            return oldValue
        }
    }
    
    /// Waits until a change in the value occurs and the predicate returns true
    public func wait(predicate: (Value) -> Bool) {
        condition.lock()
        while !predicate(_value) {
            condition.wait()
        }
        condition.unlock()
    }
}
