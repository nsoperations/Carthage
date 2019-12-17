
@testable import CarthageKit
import Foundation
import Nimble
import XCTest
import ReactiveSwift
import Result

class ConcurrencyTests: XCTestCase {
    
    func testConcurrent() {
        
        let concurrentQueue = ConcurrentProducerQueue(name: "org.carthage.CarthageKit", limit: 1)
        
        var array = [String]()
        for _ in 0..<100 {
            array.append(UUID().description)
        }
        
        var outArray = [String]()
        
        let signalProducer = SignalProducer(array)
            .flatMap(.concurrent(limit: 4)) { string -> SignalProducer<String, NoError> in
                
                return SignalProducer(value: string).map { string in
                    print("Thread \(Thread.current): \(string)")
                    outArray.append(string)
                    return string
                }
                
                //.startOnQueue(concurrentQueue)
            }
        
        _ = signalProducer.collect().first()
    }
}
