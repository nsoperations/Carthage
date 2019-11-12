@testable import CarthageKit
import Nimble
import XCTest

class AlgorithmTests: XCTestCase {
	
	typealias Graph = [String: Set<String>]
	
	var validGraph: Graph!
	var cycleGraph: Graph!
	var malformedGraph: Graph!
	
	override func setUp() {
		validGraph = [:]
		cycleGraph = [:]
		malformedGraph = [:]
		validGraph["Argo"] = Set([])
		validGraph["Commandant"] = Set(["Result"])
		validGraph["PrettyColors"] = Set([])
		validGraph["Carthage"] = Set(["Argo", "Commandant", "PrettyColors", "ReactiveCocoa", "ReactiveTask"])
		validGraph["ReactiveCocoa"] = Set(["Result"])
		validGraph["ReactiveTask"] = Set(["ReactiveCocoa"])
		validGraph["Result"] = Set()
		
		cycleGraph["A"] = Set(["B"])
		cycleGraph["B"] = Set(["C"])
		cycleGraph["C"] = Set(["A"])
		
		malformedGraph["A"] = Set(["B"])
	}
	
	func testShouldSortFirstByDependencyAndSecondByComparability() throws {
        let sorted = try Algorithms.topologicalSort(validGraph).get()
		
		expect(sorted) == [
			"Argo",
			"PrettyColors",
			"Result",
			"Commandant",
			"ReactiveCocoa",
			"ReactiveTask",
			"Carthage",
		]
	}
    
    func testSortWithLevel() throws {
        let sorted = try Algorithms.topologicalSortWithLevel(validGraph).get()
        
        expect(sorted) == [
            NodeLevel(level: 0, node: "Argo"),
            NodeLevel(level: 0, node: "PrettyColors"),
            NodeLevel(level: 0, node: "Result"),
            NodeLevel(level: 1, node: "Commandant"),
            NodeLevel(level: 1, node: "ReactiveCocoa"),
            NodeLevel(level: 2, node: "ReactiveTask"),
            NodeLevel(level: 3, node: "Carthage"),
        ]
    }
	
	func testShouldOnlyIncludeTheProvidedNodeAndItsTransitiveDependencies1() throws {
        let sorted = try Algorithms.topologicalSort(validGraph, nodes: Set(["ReactiveTask"])).get()
		
		expect(sorted) == [
			"Result",
			"ReactiveCocoa",
			"ReactiveTask",
		]
	}
	
	func testShouldOnlyIncludeProvidedNodesAndTheirTransitiveDependencies2() throws {
        let sorted = try Algorithms.topologicalSort(validGraph, nodes: Set(["ReactiveTask", "Commandant"])).get()
		
		expect(sorted) == [
			"Result",
			"Commandant",
			"ReactiveCocoa",
			"ReactiveTask",
		]
	}
	
	func testShouldOnlyIncludeProvidedNodesAndTheirTransitiveDependencies3() throws {
        let sorted = try Algorithms.topologicalSort(validGraph, nodes: Set(["Carthage"])).get()
		
		expect(sorted) == [
			"Argo",
			"PrettyColors",
			"Result",
			"Commandant",
			"ReactiveCocoa",
			"ReactiveTask",
			"Carthage",
		]
	}
	
	func testShouldPerformATopologicalSortOnTheProvidedGraphWhenTheSetIsEmpty() throws {
        let sorted = try Algorithms.topologicalSort(validGraph, nodes: nil).get()
		
		expect(sorted) == [
			"Argo",
			"PrettyColors",
			"Result",
			"Commandant",
			"ReactiveCocoa",
			"ReactiveTask",
			"Carthage",
		]
	}
	
	func testShouldFailWhenThereIsACycleInTheInputGraph1() throws {
		let sorted = Algorithms.topologicalSort(cycleGraph)

        switch sorted {
        case let .failure(error):
            switch error {
            case let .cycle(nodes):
                XCTAssertEqual(nodes.count, 4)
                XCTAssertEqual(nodes.first, nodes.last)
            default:
                fail("Unexpected error: \(error)")
            }
        default:
            fail("Expected an error to occur")
        }
	}
	
	func testShouldFailWhenThereIsACycleInTheInputGraph2() {
		let sorted = Algorithms.topologicalSort(cycleGraph, nodes: Set(["B"]))
		
		switch sorted {
        case let .failure(error):
            switch error {
            case let .cycle(nodes):
                XCTAssertEqual(nodes.count, 4)
                XCTAssertEqual(nodes.first, nodes.last)
            default:
                fail("Unexpected error: \(error)")
            }
        default:
            fail("Expected an error to occur")
        }
	}


	func testShouldFailWhenTheInputGraphIsMissingNodes1() {
		let sorted = Algorithms.topologicalSort(malformedGraph)
		
		switch sorted {
        case let .failure(error):
            switch error {
            case let .missing(node):
                XCTAssertEqual(node, "B")
            default:
                fail("Unexpected error: \(error)")
            }
        default:
            fail("Expected an error to occur")
        }
	}

	func testShouldFailWhenTheInputGraphIsMissingNodes2() {
		let sorted = Algorithms.topologicalSort(malformedGraph, nodes: Set(["A"]))
		
		switch sorted {
        case let .failure(error):
            switch error {
            case let .missing(node):
                XCTAssertEqual(node, "B")
            default:
                fail("Unexpected error: \(error)")
            }
        default:
            fail("Expected an error to occur")
        }
	}
}
