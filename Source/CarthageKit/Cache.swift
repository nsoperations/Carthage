import Foundation

/**
 This class encapsulates basic dictionary operations with expiring values. This is intentionally implemented as a final class instead of a struct to allow a timer to target it for regular removal.
 Also we don't want value semantics for a cache to avoid copying around the values.

 Each stored value has an optional timeToLive which overrides the defaultTimeToLive which is supplied to the initializer.

 This class is implemented in a thread-safe manner and is usable concurrently from multiple threads.
 */
public final class Cache<K: Hashable, V> {

    // MARK: - Public properties

    /**
     Returns the non-expired entries of this storage as a dictionary.
     */
    public var dictionary: [K: V] {
        return synchronized(self) {
            return storage.reduce(into: [K: V](minimumCapacity: storage.count)) { dict, entry in
                if !entry.value.isExpired {
                    dict[entry.key] = entry.value.value
                }
            }
        }
    }

    /**
     Returns the size of the cache (including any expired values which have not yet been removed).
     */
    public var count: Int {
        return synchronized(self) {
            return storage.count
        }
    }

    public let defaultTimeToLive: TimeInterval

    // MARK: - Internal properties

    internal var compactCount = 0

    // MARK: - Private properties

    private var storage = [K: ExpiringValue<V>]()
    private var compactTimer: DispatchSourceTimer?

    // MARK: - Object lifecycle

    /**
     Designated initializer which specifies an optional defaultTimeToLive and a compactInterval in case a timer should be scheduled to automatically compact the cache at regular times.
     */
    public init(defaultTimeToLive: TimeInterval = TimeInterval.greatestFiniteMagnitude, compactInterval: TimeInterval? = nil) {
        self.defaultTimeToLive = defaultTimeToLive
        if let interval = compactInterval {
            //Triggers in a background queue, so won't disturb the main thread
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                self?.compact()
            }
            timer.resume()
            compactTimer = timer
        }
    }

    deinit {
        compactTimer?.cancel()
    }

    // MARK: - Public methods

    /**
     Retrieves the value for the specified key.

     Returns nil if no value exists for this key or if the value has expired.
     */
    public subscript(_ key: K) -> V? {
        get {
            return synchronized(self) {
                if let value = storage[key] {
                    if value.isExpired {
                        storage.removeValue(forKey: key)
                    } else {
                        return value.value
                    }
                }
                return nil
            }
        }

        set {
            if let value = newValue {
                updateValue(value, forKey: key)
            } else {
                removeValue(forKey: key)
            }
        }
    }

    /**
     Retrieves or sets the value for the specified key with a specified expirationDate.

     The expiration date has no effect on the getter, only the setter.

     Returns nil if no value exists for this key or if the value has expired.
     */
    public subscript(_ key: K, expiringAt expirationDate: Date?) -> V? {
        get {
            return self[key]
        }

        set {
            if let value = newValue {
                updateValue(value, forKey: key, expirationDate: expirationDate)
            } else {
                removeValue(forKey: key)
            }
        }
    }

    /**
     Retrieves or sets the value for the specified key with a specified timeToLive (time interval added to the current date).

     The timeToLive has no effect on the getter, only the setter.

     Returns nil if no value exists for this key or if the value has expired.
     */
    public subscript(_ key: K, timeToLive timeToLive: TimeInterval) -> V? {
        get {
            return self[key]
        }

        set {
            if let value = newValue {
                updateValue(value, forKey: key, expirationDate: Date(timeIntervalSinceNow: timeToLive))
            } else {
                removeValue(forKey: key)
            }
        }
    }

    /**
     Puts the value for the specified key and returns the old value if present.

     If expirationDate is specified, the stored value will automatically expire after the specified date. If no expiration date is specified the default time to live is used.
     */
    @discardableResult
    public func updateValue(_ value: V, forKey key: K, expirationDate: Date? = nil) -> V? {
        return synchronized(self) {
            return storage.updateValue(ExpiringValue(value, expirationDate: expirationDate ?? Date(timeIntervalSinceNow: defaultTimeToLive)), forKey: key).map { $0.value }
        }
    }

    /**
     Removes the value for the specified key.
     */
    @discardableResult
    public func removeValue(forKey key: K) -> V? {
        return synchronized(self) {
            if let value = storage.removeValue(forKey: key) {
                return value.value
            }
            return nil
        }
    }

    /**
     Removes all stored values.
     */
    public func removeAll() {
        synchronized(self) {
            storage.removeAll()
        }
    }

    /**
     Ensures expired values are removed from the storage.
     */
    public func compact() {
        synchronized(self) {
            storage = storage.filter { !$1.isExpired }
            compactCount += 1
        }
    }

    /**
      Gets the value corresponding with the specified key and, if not found, will invoke the initializer to initialize and set it first.
    */
    public func getValue(key: K, default constructor: (K) throws -> V) rethrows -> V {
        if let value = self[key] {
            return value
        }
        let value = try constructor(key)
        self[key] = value
        return value
    }

    // MARK: - ExpiringValue

    private struct ExpiringValue<V> {
        let value: V
        let expirationDate: Date?

        var isExpired: Bool {
            return isExpired(forDate: Date())
        }

        func isExpired(forDate date: Date) -> Bool {
            return expirationDate.map { $0 < date } ?? false
        }

        init(_ value: V, expirationDate: Date?) {
            self.value = value
            self.expirationDate = expirationDate
        }
    }
}

/**
 Swift equivalence of @synchronized in ObjectiveC until a native language alternative comes around.
 */
@discardableResult
private func synchronized<T>(_ object: AnyObject, closure: () throws -> T) rethrows -> T {
    objc_sync_enter(object)
    defer {
        objc_sync_exit(object)
    }
    return try closure()
}
