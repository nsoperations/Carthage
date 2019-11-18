import Foundation
import Result

enum TopologicalSortError<Node: Comparable>: Error {
    case cycle(nodes: [Node])
    case missing(node: Node)
}

struct NodeLevel<Node: Comparable>: Comparable {
    static func < (lhs: NodeLevel<Node>, rhs: NodeLevel<Node>) -> Bool {
        guard lhs.level == rhs.level else {
            return lhs.level < rhs.level
        }
        return lhs.node < rhs.node
    }
    
    public let level: Int
    public let node: Node
}

final class Algorithms {

    /// Returns an array containing the topologically sorted nodes of the provided
    /// directed graph, or nil if the graph contains a cycle or is malformed.
    ///
    /// The sort is performed using
    /// [Khan's Algorithm](https://en.wikipedia.org/wiki/Topological_sorting#Kahn.27s_algorithm).
    ///
    /// The provided graph should be encoded as a dictionary where:
    /// - The keys are the nodes of the graph
    /// - The values are the set of nodes that the key node has a incoming edge from
    ///
    /// For example, the following graph:
    /// ```
    /// A <-- B
    /// ^     ^
    /// |     |
    /// C <-- D
    /// ```
    /// should be encoded as:
    /// ```
    /// [ A: Set([B, C]), B: Set([D]), C: Set([D]), D: Set() ]
    /// ```
    /// and would be sorted as:
    /// ```
    /// [D, B, C, A]
    /// ```
    ///
    /// Nodes that are equal from a topological perspective are sorted by the
    /// strict total order as defined by `Comparable`.
    static func topologicalSort<Node: Comparable>(_ graph: [Node: Set<Node>]) -> Result<[Node], TopologicalSortError<Node>> {
        // Maintain a list of nodes with no incoming edges (sources).
        var sources = graph
            .filter { _, incomingEdges in incomingEdges.isEmpty }
            .map { node, _ in node }

        // Maintain a working graph with all sources removed.
        var workingGraph = graph
        for node in sources {
            workingGraph.removeValue(forKey: node)
        }

        var sorted: [Node] = []

        while !sources.isEmpty {
            sources.sort(by: >)

            let lastSource = sources.removeLast()
            sorted.append(lastSource)

            for (node, var incomingEdges) in workingGraph where incomingEdges.contains(lastSource) {
                incomingEdges.remove(lastSource)
                workingGraph[node] = incomingEdges

                if incomingEdges.isEmpty {
                    sources.append(node)
                    workingGraph.removeValue(forKey: node)
                }
            }
        }
        return workingGraph.isEmpty ? .success(sorted) : .failure(sortError(graph: workingGraph))
    }
    
    static func topologicalSortWithLevel<Node>(_ graph: [Node: Set<Node>]) -> Result<[NodeLevel<Node>], TopologicalSortError<Node>> {
        // Maintain a list of nodes with no incoming edges (sources).
        
        var workingGraph = Dictionary<Node, MutableSet<Node>>(minimumCapacity: graph.count)
        let sources = LinkedList<NodeLevel<Node>>()
        var totalCount = 0
        
        for (node, incomingEdges) in graph {
            if incomingEdges.isEmpty {
                sources.append(NodeLevel(level: 0, node: node))
            } else {
                workingGraph[node] = MutableSet(incomingEdges)
            }
            totalCount += 1
        }
        
        var sorted: [NodeLevel<Node>] = []
        sorted.reserveCapacity(totalCount)
        
        while true {
            guard let firstSource = sources.popFirst() else {
                break
            }
            sorted.append(firstSource)
            
            for (node, incomingEdges) in workingGraph {
                if incomingEdges.remove(firstSource.node) != nil {
                    if incomingEdges.isEmpty {
                        sources.append(NodeLevel(level: firstSource.level + 1, node: node))
                        workingGraph.removeValue(forKey: node)
                    }
                }
            }
        }
        
        if workingGraph.isEmpty {
            return .success(sorted.sorted())
        } else {
            let remainingGraph = workingGraph.reduce(into: [Node: Set<Node>]()) { dict, entry in
                dict[entry.key] = entry.value.set
            }
            return .failure(sortError(graph: remainingGraph))
        }
    }

    private static func sortError<Node>(graph: [Node: Set<Node>]) -> TopologicalSortError<Node> {

        // Assuming for graph now all nodes have incoming edges
        guard var nextNode = graph.first?.key else {
            preconditionFailure("Graph should not be empty")
        }

        var handledNodeIndexes = [Node: Int]()
        var cycle = [Node]()

        repeat {
            handledNodeIndexes[nextNode] = cycle.count
            cycle.append(nextNode)
            guard let next = graph[nextNode]?.first else {
                return .missing(node: nextNode)
            }
            nextNode = next
        } while handledNodeIndexes[nextNode] == nil

        let firstIndex = handledNodeIndexes[nextNode]!
        return .cycle(nodes: Array(cycle[firstIndex..<cycle.count]) + [nextNode])
    }

    /// Performs a topological sort on the provided graph with its output sorted to
    /// include only the provided set of nodes and their transitively incoming
    /// nodes (dependencies).
    ///
    /// If the provided `nodes` set is nil, returns the result of invoking
    /// `topologicalSort()` with the provided graph.
    ///
    /// Throws an exception if the provided node(s) are not contained within the
    /// given graph.
    ///
    /// Returns nil if the provided graph has a cycle or is malformed.
    static func topologicalSort<Node: Comparable>(_ graph: [Node: Set<Node>], nodes: Set<Node>?) -> Result<[Node], TopologicalSortError<Node>> {
        guard let includeNodes = nodes else {
            return Algorithms.topologicalSort(graph)
        }

        precondition(includeNodes.isSubset(of: Set(graph.keys)))

        // Ensure that the graph has no cycles, otherwise determining the set of
        // transitive incoming nodes could infinitely recurse.
        let result = Algorithms.topologicalSort(graph)
        guard let sorted = try? result.get() else {
            return result
        }

        let relevantNodes = Set(includeNodes.flatMap { (node: Node) -> Set<Node> in
            Set([node]).union(Algorithms.transitiveIncomingNodes(graph, node: node))
        })

        return .success(sorted.filter { node in relevantNodes.contains(node) })
    }
    
    static func topologicalSortWithLevel<Node: Comparable>(_ graph: [Node: Set<Node>], nodes: Set<Node>?) -> Result<[NodeLevel<Node>], TopologicalSortError<Node>> {
        guard let includeNodes = nodes else {
            return Algorithms.topologicalSortWithLevel(graph)
        }

        precondition(includeNodes.isSubset(of: Set(graph.keys)))

        // Ensure that the graph has no cycles, otherwise determining the set of
        // transitive incoming nodes could infinitely recurse.
        let result = Algorithms.topologicalSortWithLevel(graph)
        guard let sorted = try? result.get() else {
            return result
        }

        let relevantNodes = Set(includeNodes.flatMap { (node: Node) -> Set<Node> in
            Set([node]).union(Algorithms.transitiveIncomingNodes(graph, node: node))
        })

        return .success(sorted.filter { nodeLevel in relevantNodes.contains(nodeLevel.node) })
    }

    /// Returns the set of nodes that the given node in the provided graph has as
    /// its incoming nodes, both directly and transitively.
    private static func transitiveIncomingNodes<Node>(_ graph: [Node: Set<Node>], node: Node) -> Set<Node> {
        guard let nodes = graph[node] else {
            return Set()
        }

        let incomingNodes = Set(nodes.flatMap { Algorithms.transitiveIncomingNodes(graph, node: $0) })

        return nodes.union(incomingNodes)
    }

}

private final class MutableSet<Element: Hashable> {
    
    public private(set) var set: Set<Element>
    
    init(_ set: Set<Element>) {
        self.set = set
    }
    
    var isEmpty: Bool {
        return set.isEmpty
    }
    
    func remove(_ element: Element) -> Element? {
        return set.remove(element)
    }
}
