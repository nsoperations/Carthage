import Foundation

final class LinkedList<Element> {
    
    private var head: Node<Element>?
    private var tail: Node<Element>?
    public private(set) var count: Int = 0

    public init() {

    }

    public init<S: Sequence>(_ sequence: S) where S.Element == Element {
        self.append(contentsOf: sequence)
    }
    
    public var isEmpty: Bool {
        return count == 0
    }
    
    public var first: Element? {
        return head?.value
    }
    
    public var last: Element? {
        return tail?.value
    }
    
    public func prepend(_ element: Element) {
        count += 1
        let node = Node(element)
        if tail == nil {
            tail = node
        }
        if let currentHead = head {
            node.next = currentHead
            currentHead.previous = node
        }
        head = node
    }
    
    public func append(_ element: Element) {
        count += 1
        let node = Node(element)
        if head == nil {
            head = node
        }
        if let currentTail = tail {
            node.previous = currentTail
            currentTail.next = node
        }
        tail = node
    }

    public func append<S: Sequence>(contentsOf sequence: S) where S.Element == Element {
        for element in sequence {
            self.append(element)
        }
    }
    
    public func popFirst() -> Element? {
        defer {
            if count > 0 {
                count -= 1
                head = head?.next
                if head == nil {
                    tail = nil
                }
            }
        }
        return head?.value
    }
    
    public func popLast() -> Element? {
        defer {
            if count > 0 {
                count -= 1
                tail = tail?.previous
                if tail == nil {
                    head = nil
                }
            }
        }
        return tail?.value
    }
}

extension LinkedList: Sequence {
    typealias Iterator = LinkedListIterator<Element>
    
    func makeIterator() -> Iterator {
        return Iterator(node: self.head)
    }
}

private class Node<Element> {
    var value: Element
    var next: Node<Element>?
    weak var previous: Node<Element>?
    
    public init(_ value: Element) {
        self.value = value
    }
}

final class LinkedListIterator<Element>: IteratorProtocol {
    
    private var currentNode: Node<Element>?
    
    fileprivate init(node: Node<Element>?) {
        currentNode = node
    }
    
    func next() -> Element? {
        defer {
            currentNode = currentNode?.next
        }
        return currentNode?.value
    }
}
