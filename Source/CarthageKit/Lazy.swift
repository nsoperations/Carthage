import Foundation

/// Thread safe version of the lazy property in Swift.
///
/// A normal lazy property is NOT thread safe (can be called multiple times) which may cause issues in multi-threaded scenarios.
///
/// An example (which uses Swift.Result for a constructor which may fail):
///
/// ```
/// let lazyResult: Lazy<Swift.Result<String, Error>> = Lazy {
///     return Swift.Result {
///         try String(contentsOf: URL(fileURLWithPath: "/some/file/path"))
///     }
/// }
/// // Calling .value will cause the closure to be instantiated. This is guaranteed to happen only once, even in multi-threaded scenarios.
/// let value = try lazyResult.value.get()
/// ```
public class Lazy<Value> {
    
    private let constructor: () -> Value
    fileprivate let lock: NSLock
    fileprivate var initializedValue: Value?
    
    /// Initializes with the specified constructor closure for lazy initialization of value.
    /// The constructor is called upon first call to self.value.
    ///
    /// - parameters:
    ///     - constructor: The closure which returns an initial value.
    public convenience init(constructor: @escaping () -> Value) {
        self.init(lock: NSLock(), constructor: constructor)
    }
    
    /// Convenience initializer which uses an autoclosure instead of an explicit closure
    ///
    /// - parameters:
    ///     - value: The value to use (called as autoclosure)
    public convenience init(_ value: @autoclosure @escaping () -> Value) {
        self.init(constructor: value)
    }
    
    /// Internal initializer to be able to test atomicity
    private init(lock: NSLock, constructor: @escaping () -> Value) {
        self.constructor = constructor
        self.lock = lock
    }
    
    /// Atomically initializes the value or returns the initialized value if already done before.
    public var value: Value {
        lock.lock()
        defer {
            lock.unlock()
        }
        if let definedValue = self.initializedValue {
            return definedValue
        } else {
            let definedValue = self.constructor()
            self.initializedValue = definedValue
            return definedValue
        }
    }
}

/// Thread safe version of the lazy property in Swift, which can reset it's initialized value (e.g. to clear caching)
public class ResettableLazy<Value>: Lazy<Value> {
    
    /// Resets the initialized value, such that the constructor will be called again on next access to self.value.
    ///
    /// This may be handy in the context of caching to clear a cached value.
    public func reset() {
        lock.lock()
        defer {
            lock.unlock()
        }
        self.initializedValue = nil
    }
}
