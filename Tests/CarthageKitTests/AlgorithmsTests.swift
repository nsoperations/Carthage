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
	
	func testShouldSortFirstByDependencyAndSecondByComparability() {
		let sorted = Algorithms.topologicalSort(validGraph)
		
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
	
	func testShouldOnlyIncludeTheProvidedNodeAndItsTransitiveDependencies1() {
		let sorted = Algorithms.topologicalSort(validGraph, nodes: Set(["ReactiveTask"]))
		
		expect(sorted) == [
			"Result",
			"ReactiveCocoa",
			"ReactiveTask",
		]
	}
	
	func testShouldOnlyIncludeProvidedNodesAndTheirTransitiveDependencies2() {
		let sorted = Algorithms.topologicalSort(validGraph, nodes: Set(["ReactiveTask", "Commandant"]))
		
		expect(sorted) == [
			"Result",
			"Commandant",
			"ReactiveCocoa",
			"ReactiveTask",
		]
	}
	
	func testShouldOnlyIncludeProvidedNodesAndTheirTransitiveDependencies3() {
		let sorted = Algorithms.topologicalSort(validGraph, nodes: Set(["Carthage"]))
		
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
	
	func testShouldPerformATopologicalSortOnTheProvidedGraphWhenTheSetIsEmpty() {
		let sorted = Algorithms.topologicalSort(validGraph, nodes: nil)
		
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
	
	func testShouldFailWhenThereIsACycleInTheInputGraph1() {
		let sorted = Algorithms.topologicalSort(cycleGraph)
		
		expect(sorted).to(beNil())
	}
	
	func testShouldFailWhenThereIsACycleInTheInputGraph2() {
		let sorted = Algorithms.topologicalSort(cycleGraph, nodes: Set(["B"]))
		
		expect(sorted).to(beNil())
	}


	func testShouldFailWhenTheInputGraphIsMissingNodes1() {
		let sorted = Algorithms.topologicalSort(malformedGraph)
		
		expect(sorted).to(beNil())
	}

	func testShouldFailWhenTheInputGraphIsMissingNodes2() {
		let sorted = Algorithms.topologicalSort(malformedGraph, nodes: Set(["A"]))
		
		expect(sorted).to(beNil())
	}
}
