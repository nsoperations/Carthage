import Foundation

final class LazyValue<T> {

    private let queue = DispatchQueue(label: "org.carthage.LazyValue")
    private var _value: T?
    private let _computation: () -> T

    init(computation: @escaping () -> T) {
        self._computation = computation
    }

    var value: T {
        var ret: T!
        queue.sync {
            if let value = _value {
                ret = value
            } else {
                _value = _computation()
                ret = _value
            }
        }
        return ret
    }
}
