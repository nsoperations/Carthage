@testable import CarthageKit
import Foundation
import Nimble
import XCTest
import ReactiveSwift
import Result
import Tentacle

private func ==<A: Equatable, B: Equatable>(lhs: [(A, B)], rhs: [(A, B)]) -> Bool {
	guard lhs.count == rhs.count else { return false }
	for (lhs, rhs) in zip(lhs, rhs) {
		guard lhs == rhs else { return false }
	}
	return true
}

private func equal<A: Equatable, B: Equatable>(_ expectedValue: [(A, B)]?) -> Predicate<[(A, B)]> {
	return Predicate.define("equal <\(stringify(expectedValue))>") { actualExpression, message in
		let actualValue = try actualExpression.evaluate()
		if expectedValue == nil || actualValue == nil {
			if expectedValue == nil {
				return PredicateResult(status: .fail, message: message.appendedBeNilHint())
			}
			return PredicateResult(status: .fail, message: message)
		}
		return PredicateResult(bool: expectedValue! == actualValue!, message: message)
	}
}

private func ==<A: Equatable, B: Equatable>(lhs: Expectation<[(A, B)]>, rhs: [(A, B)]) {
	lhs.to(equal(rhs))
}

class ResolverTests: XCTestCase {
	let resolverType = BackTrackingResolver.self
	
	func testShouldResolveASimpleCartfile() {
		let db: DB = [
			github1: [
				.v0_1_0: [
					github2: .compatibleWith(.v1_0_0),
				],
			],
			github2: [
				.v1_0_0: [:],
			],
			]
		
		let resolved = db.resolve(resolverType, [ github1: .exactly(.v0_1_0) ])
		
		switch resolved {
		case .success(let value):
			expect(value) == [
				github2: .v1_0_0,
				github1: .v0_1_0,
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	func testShouldResolveToTheLatestMatchingVersions() {
		let db: DB = [
			github1: [
				.v0_1_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v1_0_0: [
					github2: .compatibleWith(.v2_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v2_0_0),
				],
			],
			github2: [
				.v1_0_0: [:],
				.v2_0_0: [:],
				.v2_0_1: [:],
			],
			]
		
		let resolved = db.resolve(resolverType, [ github1: .any ])
		
		switch resolved {
		case .success(let value):
			expect(value) == [
				github2: .v2_0_1,
				github1: .v1_1_0,
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	func testShouldResolveASubsetWhenGivenSpecificDependencies() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0),
					github4: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v1_0_0),
					github4: .compatibleWith(.v1_0_0),
				],
			],
			github2: [
				.v1_0_0: [ github3: .compatibleWith(.v1_0_0) ],
				.v1_1_0: [ github3: .compatibleWith(.v1_0_0) ],
			],
			github3: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v1_2_0: [:],
			],
			github4: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v1_2_0: [:],
			],
			git1: [
				.v1_0_0: [:],
			],
			]
		
		let resolved = db.resolve(resolverType,
								  [
									github1: .any,
									// Newly added dependencies which are not included in the
									// list should be resolved to avoid invalid dependency trees.
									git1: .any,
									],
								  resolved: [ github1: .v1_0_0, github2: .v1_0_0, github3: .v1_0_0, github4: .v1_0_0 ],
								  updating: [ github2 ]
		)
		
		switch resolved {
		case .success(let value):
			expect(value) == [
                git1: .v1_0_0,
				github4: .v1_0_0,
				github3: .v1_2_0,
				github2: .v1_1_0,
				github1: .v1_0_0,
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	func testShouldUpdateADependencyThatIsInTheRootListAndNestedWhenTheParentIsMarkedForUpdate() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					git1: .compatibleWith(.v1_0_0)
				]
			],
			git1: [
				.v1_0_0: [:],
				.v1_1_0: [:]
			]
		]
		
		let resolved = db.resolve(resolverType,
								  [ github1: .any, git1: .any],
								  resolved: [ github1: .v1_0_0, git1: .v1_0_0 ],
								  updating: [ github1 ])
		
		switch resolved {
		case .success(let value):
			expect(value) == [
				github1: .v1_0_0,
				git1: .v1_1_0
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	func testShouldFailWhenGivenIncompatibleNestedVersionSpecifiers() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					git1: .compatibleWith(.v1_0_0),
					github2: .any,
				],
			],
			github2: [
				.v1_0_0: [
					git1: .compatibleWith(.v2_0_0),
				],
			],
			git1: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v2_0_0: [:],
				.v2_0_1: [:],
			]
		]
		let resolved = db.resolve(resolverType, [github1: .any])
		expect(resolved.value).to(beNil())
		expect(resolved.error).notTo(beNil())
	}
	
	func testShouldCorrectlyResolveWhenSpecifiersIntersect() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0)
				]
			],
			github2: [
				.v1_0_0: [:],
				.v2_0_0: [:]
			]
		]
		
		let resolved = db.resolve(resolverType, [ github1: .any, github2: .atLeast(.v1_0_0) ])
		
		switch resolved {
		case .success(let value):
			expect(value) == [
				github1: .v1_0_0,
				github2: .v1_0_0
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	func testShouldFailOnIncompatibleDependencies() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github2: .compatibleWith(.v2_0_0),
				],
			],
			github2: [
				.v1_0_0: [ github3: .compatibleWith(.v2_0_0) ],
				.v2_0_0: [ github3: .compatibleWith(.v2_0_0) ],
			],
			github3: [
				.v1_0_0: [:],
				.v2_0_0: [:],
			],
			]
		
		let resolved = db.resolve(resolverType, [ github1: .any, github2: .compatibleWith(.v1_0_0), github3: .compatibleWith(.v1_0_0) ])
		expect(resolved.value).to(beNil())
		expect(resolved.error).notTo(beNil())
	}
	
	func testShouldResolveASubsetWhenGivenSpecificDependenciesThatHaveConstraints() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github2: .compatibleWith(.v2_0_0),
				],
			],
			github2: [
				.v1_0_0: [ github3: .compatibleWith(.v1_0_0) ],
				.v1_1_0: [ github3: .compatibleWith(.v1_0_0) ],
				.v2_0_0: [:],
			],
			github3: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v1_2_0: [:],
			],
			]
		
		let resolved = db.resolve(resolverType,
								  [ github1: .any ],
								  resolved: [ github1: .v1_0_0, github2: .v1_0_0, github3: .v1_0_0 ],
								  updating: [ github2 ]
		)
		
		switch resolved {
		case .success(let value):
			expect(value) == [
				github3: .v1_2_0,
				github2: .v1_1_0,
				github1: .v1_0_0,
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	
	func testShouldFailWhenTheOnlyValidGraphIsNotInTheSpecifiedDependencies() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github2: .compatibleWith(.v2_0_0),
				],
			],
			github2: [
				.v1_0_0: [ github3: .compatibleWith(.v1_0_0) ],
				.v1_1_0: [ github3: .compatibleWith(.v1_0_0) ],
				.v2_0_0: [:],
			],
			github3: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v1_2_0: [:],
			],
			]
		let resolved = db.resolve(resolverType,
								  [ github1: .exactly(.v2_0_0) ],
								  resolved: [ github1: .v1_0_0, github2: .v1_0_0, github3: .v1_0_0 ],
								  updating: [ github2 ]
		)
		expect(resolved.value).to(beNil())
		expect(resolved.error).notTo(beNil())
	}
	
	
	func testShouldResolveACartfileWhoseDependencyIsSpecifiedByBothABranchNameAndAShaWhichIsTheHeadOfThatBranch() {
		let branch = "development"
		let sha = "8ff4393ede2ca86d5a78edaf62b3a14d90bffab9"
		
		var db: DB = [
			github1: [
				.v1_0_0: [
					github2: .any,
					github3: .gitReference(sha),
				],
			],
			github2: [
				.v1_0_0: [
					github3: .gitReference(branch),
				],
			],
			github3: [
				.v1_0_0: [:],
			],
			]
		db.references = [
			github3: [
				branch: PinnedVersion(sha),
				sha: PinnedVersion(sha),
			],
		]
		
		let resolved = db.resolve(resolverType, [ github1: .any, github2: .any ])
		
		switch resolved {
		case .success(let value):
			expect(value) == [
				github3: PinnedVersion(sha),
				github2: .v1_0_0,
				github1: .v1_0_0,
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	func testShouldCorrectlyOrderTransitiveDependencies() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .any,
					github3: .any,
				],
			],
			github2: [
				.v1_0_0: [
					github3: .any,
					git1: .any,
				],
			],
			github3: [
				.v1_0_0: [ git2: .any ],
			],
			git1: [
				.v1_0_0: [ github3: .any ],
			],
			git2: [
				.v1_0_0: [:],
			],
			]
		
		let resolved = db.resolve(resolverType, [ github1: .any ])
		
		switch resolved {
		case .success(let value):
			expect(value) == [
				git2: .v1_0_0,
				github3: .v1_0_0,
				git1: .v1_0_0,
				github2: .v1_0_0,
				github1: .v1_0_0,
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	func testShouldFailIfNoVersionsMatchTheRequirementsAndPrereleaseVersionsExist() {
		let db: DB = [
			github1: [
				.v1_0_0: [:],
				.v2_0_0_beta_1: [:],
				.v2_0_0: [:],
				.v3_0_0_beta_1: [:],
			],
			]
		
		do {
			let resolved = db.resolve(resolverType, [ github1: .atLeast(.v3_0_0) ])
			expect(resolved.value).to(beNil())
			expect(resolved.error).notTo(beNil())
		}
		
		do {
			let resolved = db.resolve(resolverType, [ github1: .compatibleWith(.v3_0_0) ])
			expect(resolved.value).to(beNil())
			expect(resolved.error).notTo(beNil())
		}
		
		do {
			let resolved = db.resolve(resolverType, [ github1: .exactly(.v3_0_0) ])
			expect(resolved.value).to(beNil())
			expect(resolved.error).notTo(beNil())
		}
	}
	
	func testShouldCorrectlyResolveComplexConflictingDependencies() {
		
		guard let testCartfileURL = Bundle(for: ResolverTests.self).url(forResource: "Resolver/ConflictingDependencies/Cartfile", withExtension: "") else {
			fail("Could not load Resolver/ConflictingDependencies/Cartfile from resources")
			return
		}
		let projectDirectoryURL = testCartfileURL.deletingLastPathComponent()
		let repositoryURL = projectDirectoryURL.appendingPathComponent("Repository")
		
		let project = Project(directoryURL: projectDirectoryURL)
		let repository = LocalDependencyStore(directoryURL: repositoryURL)
		
		let signalProducer = project.resolveUpdatedDependencies(from: repository,
																resolverType: resolverType.self,
																dependenciesToUpdate: nil)
		do {
			_ = try signalProducer.first()?.get()
			fail("Expected incompatibility error to be thrown")
		} catch CarthageError.incompatibleRequirements {
            //OK
        } catch {
			fail("Expected incompatibleRequirements error to be thrown, but got: \(error)")
		}
	}
    
    func testShouldCorrectlyHandleGitReferences() {
        guard let testCartfileURL = Bundle(for: ResolverTests.self).url(forResource: "Resolver/GitReference/Cartfile", withExtension: "") else {
            fail("Could not load Resolver/GitReference/Cartfile from resources")
            return
        }
        let projectDirectoryURL = testCartfileURL.deletingLastPathComponent()
        let repositoryURL = projectDirectoryURL.appendingPathComponent("Repository")
        
        let project = Project(directoryURL: projectDirectoryURL)
        let repository = LocalDependencyStore(directoryURL: repositoryURL)
        
        do {
            let cartfile = try Cartfile.from(fileURL: testCartfileURL).get()

            guard let resolvedCartfile1 = try project.resolveUpdatedDependencies(from: repository,
                                                                                 resolverType: resolverType.self,
                                                                                 dependenciesToUpdate: nil).first()?.get() else {
                fail("Could not load resolved cartfile")
                return
            }
            
            guard let pinnedVersionSwiftySRP1 = resolvedCartfile1.version(for: "SwiftySRP") else {
                fail("SwiftySRP was not resolved")
                return
            }
            
            expect(pinnedVersionSwiftySRP1.commitish) == "17dd563b23a524d332dcf53808e6ab5da9eadf55"
            
            guard let pinnedVersionSecurity1 = resolvedCartfile1.version(for: "Security") else {
                fail("Security was not resolved")
                return
            }
            
            expect(pinnedVersionSecurity1.semanticVersion) == SemanticVersion(2, 1, 0)
            
            // Test whether the resolved cartfile is valid (should be the case)
            try project.validate(cartfile: cartfile, resolvedCartfile: resolvedCartfile1, dependencyRetriever: repository).first()?.get()
            
            // Now resolve only Security, should yield the same result
            
            guard let resolvedCartfile2 = try project.resolveUpdatedDependencies(from: repository,
                                               resolverType: resolverType.self,
                                               dependenciesToUpdate: ["Security"]).first()?.get() else {
                fail("Could not load resolved cartfile")
                return
            }
            
            guard let pinnedVersionSwiftySRP2 = resolvedCartfile2.version(for: "SwiftySRP") else {
                fail("SwiftySRP was not resolved")
                return
            }
            
            expect(pinnedVersionSwiftySRP2.commitish) == "17dd563b23a524d332dcf53808e6ab5da9eadf55"
            
            guard let pinnedVersionSecurity2 = resolvedCartfile2.version(for: "Security") else {
                fail("Security was not resolved")
                return
            }
            
            expect(pinnedVersionSecurity2.semanticVersion) == SemanticVersion(2, 1, 0)
            
            // Test whether the resolved cartfile is valid (should be the case)
            try project.validate(cartfile: cartfile, resolvedCartfile: resolvedCartfile2, dependencyRetriever: repository).first()?.get()
            
        } catch {
            fail("Expected no error to be thrown, but got: \(error)")
        }
        
        
    }
	
	func testShouldCorrectlyResolveTheLatestVersion() {
		
		guard let testCartfileURL = Bundle(for: ResolverTests.self).url(forResource: "Resolver/LatestVersion/Cartfile", withExtension: "") else {
			fail("Could not load Resolver/LatestVersion/Cartfile from resources")
			return
		}
		let projectDirectoryURL = testCartfileURL.deletingLastPathComponent()
		let repositoryURL = projectDirectoryURL.appendingPathComponent("Repository")
		
		let project = Project(directoryURL: projectDirectoryURL)
		let repository = LocalDependencyStore(directoryURL: repositoryURL)
		
		let signalProducer = project.resolveUpdatedDependencies(from: repository,
																resolverType: resolverType.self,
																dependenciesToUpdate: nil)
		do {
			guard let resolvedCartfile = try signalProducer.first()?.get() else {
				fail("Could not load resolved cartfile")
				return
			}
			
			if let facebookDependency = resolvedCartfile.dependencies.first(where: { $0.key.name == "facebook-ios-sdk" }) {
				expect(facebookDependency.value.commitish.hasSuffix("4.33.0")) == true
			} else {
				fail("Expected facebook dependency to be present")
			}
			
			//Should not throw an error
			guard let _ = try project.buildOrderForResolvedCartfile(resolvedCartfile).first()?.get() else {
				fail("Could not determine build order for resolved cartfile")
				return
			}
			
		} catch {
			fail("Unexpected error thrown: \(error)")
		}
	}
	
	func testShouldCorrectlyResolveItemsWithConflictingNamesGivingPrecedenceToPinnedVersions() {
		guard let testCartfileURL = Bundle(for: ResolverTests.self).url(forResource: "Resolver/ConflictingNames/Cartfile", withExtension: "") else {
			fail("Could not load Resolver/ConflictingNames/Cartfile from resources")
			return
		}
		let projectDirectoryURL = testCartfileURL.deletingLastPathComponent()
		let repositoryURL = projectDirectoryURL.appendingPathComponent("Repository")
		
		let project = Project(directoryURL: projectDirectoryURL)
        let repository = LocalDependencyStore(directoryURL: repositoryURL)
        let signalProducer = project.resolveUpdatedDependencies(from: repository,
																resolverType: resolverType.self,
                                                                dependenciesToUpdate: nil)
		do {
			guard let resolvedCartfile = try signalProducer.first()?.get() else {
				fail("Could not load resolved cartfile")
				return
			}
			
			if let kissXMLDependency = resolvedCartfile.dependencies.first(where: { $0.key.name == "KissXML" }) {
				expect(kissXMLDependency.value.commitish) == "88665bed750e0fec9ad8e1ffc992b5b3812008d3"
			} else {
				fail("Expected kissXMLDependency dependency to be present")
			}
			
			//Should not throw an error
			guard let _ = try project.buildOrderForResolvedCartfile(resolvedCartfile).first()?.get() else {
				fail("Could not determine build order for resolved cartfile")
				return
			}
			
		} catch {
			fail("Unexpected error thrown: \(error)")
		}
	}
	
	func testShouldCorrectlyUpdateSubsetOfDependenciesIgnoringUnspecifiedTransitiveDependencies() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0),
					github3: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v1_0_0),
					github3: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github2: .compatibleWith(.v1_0_0),
					github3: .compatibleWith(.v1_0_0),
				],
			],
			github2: [
				.v1_0_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
			],
			github3: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v2_0_0: [:],
			],
			git1: [
				.v1_0_0: [ github3: .any ],
				.v1_1_0: [ github3: .any ],
				.v2_0_0: [ github3: .any ],
			],
			git2: [
				.v1_0_0: [:],
				.v1_1_0: [:],
			],
			]
		
		let resolved = db.resolve(resolverType,
								  [ github1: .any,
									git2: .any],
								  resolved: [ github1: .v1_0_0,
											  github2: .v1_0_0,
											  github3: .v1_0_0,
											  git1: .v1_0_0,
											  git2: .v1_0_0],
								  updating: [github1])
		
		// Github1 should be updated, including its transitive dependencies. Other dependencies should remain static.
		switch resolved {
		case .success(let value):
			expect(value) == [
				github3: .v1_1_0,
				git1: .v1_1_0,
				github2: .v1_1_0,
				github1: .v2_0_0,
				git2: .v1_0_0
			]
		case .failure(let error):
			fail("Expected no error to occur: \(error)")
		}
	}
	
	func testShouldCorrectlyFailUpdateSubsetOfDependenciesIfNoResolutionExistsWithTheSpecifiedDependenciesToUpdate() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0),
					github3: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v1_0_0),
					github3: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github2: .compatibleWith(.v1_0_0),
					github3: .compatibleWith(.v1_0_0),
				],
			],
			github2: [
				.v1_0_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
			],
			github3: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v2_0_0: [:],
			],
			git1: [
				.v1_0_0: [ github3: .any ],
				.v1_1_0: [ github3: .any ],
				.v2_0_0: [ github3: .any ],
			],
			git2: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v2_0_0: [:],
			],
			]
		
		let resolved = db.resolve(resolverType,
								  [ github1: .any,
									git2: .compatibleWith(.v2_0_0)],
								  resolved: [ github1: .v1_0_0,
											  github2: .v1_0_0,
											  github3: .v1_0_0,
											  git1: .v1_0_0,
											  git2: .v1_0_0],
								  updating: [github1])
		
		// Github1 should be updated, including its transitive dependencies. Other dependencies should remain static.
		switch resolved {
		case .success(let value):
			fail("Expected an error to occur, but got value: \(value)")
		case .failure(let error):
			// OK
			if case let CarthageError.unsatisfiableDependencyList(dependencyList) = error {
				//OK
				expect(dependencyList) == [github1.name]
			} else {
				fail("Got wrong type of error, expected unsatisfiableDependencyList but got: \(error)")
			}
		}
	}
	
	func testShouldCorrectlyFailUpdateSubsetOfDependenciesIfNoResolutionIsPossibleBecauseARequiredVersionDoesNotExist() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0),
					github3: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v1_0_0),
					github3: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github2: .compatibleWith(.v2_0_0),
					github3: .compatibleWith(.v3_0_0),
				],
			],
			github2: [
				.v1_0_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github3: .compatibleWith(.v1_0_0),
					git1: .compatibleWith(.v1_0_0),
				],
			],
			github3: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v2_0_0: [:],
			],
			git1: [
				.v1_0_0: [ github3: .any ],
				.v1_1_0: [ github3: .any ],
				.v2_0_0: [ github3: .any ],
			],
			git2: [
				.v1_0_0: [:],
				.v1_1_0: [:],
				.v2_0_0: [:],
			],
			]
		
		let resolved = db.resolve(resolverType,
								  [ github1: .compatibleWith(.v2_0_0),
									git2: .compatibleWith(.v1_0_0)],
								  resolved: [ github1: .v1_0_0,
											  github2: .v1_0_0,
											  github3: .v1_0_0,
											  git1: .v1_0_0,
											  git2: .v1_0_0],
								  updating: [github1])
		
		// Github1 should be updated, including its transitive dependencies. Other dependencies should remain static.
		switch resolved {
		case .success(let value):
			fail("Expected an error to occur, but got value: \(value)")
		case .failure(let error):
			// OK
			if case let CarthageError.requiredVersionNotFound(dependency, versionSpecifier) = error {
				//OK
				expect(dependency) == github3
				expect(versionSpecifier) == .compatibleWith(.v3_0_0)
			} else {
				fail("Got wrong type of error, expected requiredVersionNotFound but got: \(error)")
			}
		}
	}
	
	func testShouldFailOnCyclicDependencies() {
		let db: DB = [
			github1: [
				.v1_0_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v1_1_0: [
					github2: .compatibleWith(.v1_0_0),
				],
				.v2_0_0: [
					github2: .compatibleWith(.v2_0_0),
				],
			],
			github2: [
				.v1_0_0: [ github3: .compatibleWith(.v1_0_0) ],
			],
			github3: [
				.v1_0_0: [ github1: .compatibleWith(.v1_0_0)],
			],
			]
		
		let resolved = db.resolve(resolverType, [ github1: .any, github2: .any ])
		expect(resolved.value).to(beNil())
		expect(resolved.error).notTo(beNil())
		if let error = resolved.error {
			switch error {
			case let .dependencyCycle(nodes):
                XCTAssertEqual(nodes.count, 4)
                XCTAssertEqual(nodes.last, nodes.first)
			default:
				fail("Expected error to be of type .dependencyCycle")
			}
		}
	}
}

extension Project {
    /// Updates dependencies by using the specified local dependency store instead of 'live' lookup for dependencies and their versions
    /// Returns a signal with the resulting ResolvedCartfile upon success or a CarthageError upon failure.
    fileprivate func resolveUpdatedDependencies<T: ResolverProtocol>(
        from store: LocalDependencyStore,
        resolverType: T.Type,
        dependenciesToUpdate: [String]? = nil,
        configuration: ((T) -> Void)? = nil) -> SignalProducer<ResolvedCartfile, CarthageError> {
        
        let resolver = resolverType.init(projectDependencyRetriever: store)
        configuration?(resolver)
        return updatedResolvedCartfile(dependenciesToUpdate, resolver: resolver)
    }
}

final class ResolverEventLogger {
    
    init() {}
    
    func log(event: ResolverEvent) {
        switch event {
        case .foundVersions(let versions, let dependency, let versionSpecifier):
            print("Versions for dependency '\(dependency)' compatible with versionSpecifier \(versionSpecifier): \(versions)")
        case .foundTransitiveDependencies(let transitiveDependencies, let dependency, let version):
            print("Dependencies for dependency '\(dependency)' with version \(version): \(transitiveDependencies)")
        case .failedRetrievingTransitiveDependencies(let error, let dependency, let version):
            print("Caught error while retrieving dependencies for \(dependency) at version \(version): \(error)")
        case .failedRetrievingVersions(let error, let dependency, _):
            print("Caught error while retrieving versions for \(dependency): \(error)")
        case .rejected(let dependencySet, let error):
            print("Rejected dependency set:\n\(dependencySet)\n\nReason: \(error)\n")
        }
    }
}

