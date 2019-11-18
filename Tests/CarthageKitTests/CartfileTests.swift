import CarthageKit
import Foundation
import Result
import Tentacle
import Nimble
import XCTest

class CartfileTests: XCTestCase {
	func testShouldParseACartfile() {
		guard let testCartfileURL = Bundle(for: type(of: self)).url(forResource: "TestCartfile", withExtension: "") else {
			fail("Could not find TestCartFile in resources")
			return
		}
		guard let testCartfile = try? String(contentsOf: testCartfileURL, encoding: .utf8) else {
			fail("Could not load Cartfile as string, is it UTF8 encoded?")
			return
		}
		
		let result = Cartfile.from(string: testCartfile)
		expect(result.error).to(beNil())
		
		guard let cartfile = result.value else {
			fail("Cartfile could not be be parsed")
			return
		}
		
		let reactiveCocoa = Dependency.gitHub(.dotCom, Repository(owner: "ReactiveCocoa", name: "ReactiveCocoa"))
		let mantle = Dependency.gitHub(.dotCom, Repository(owner: "Mantle", name: "Mantle"))
		let libextobjc = Dependency.gitHub(.dotCom, Repository(owner: "jspahrsummers", name: "libextobjc"))
		let xcconfigs = Dependency.gitHub(.dotCom, Repository(owner: "jspahrsummers", name: "xcconfigs"))
		let iosCharts = Dependency.gitHub(.dotCom, Repository(owner: "danielgindi", name: "ios-charts"))
		let errorTranslations = Dependency.gitHub(
			.enterprise(url: URL(string: "https://enterprise.local/ghe")!), Repository(owner: "desktop", name: "git-error-translations")
		)
		let errorTranslations2 = Dependency.git(GitURL("https://enterprise.local/desktop/git-error-translations2.git"))
		let example1 = Dependency.gitHub(.dotCom, Repository(owner: "ExampleOrg", name: "ExamplePrj1"))
		let example2 = Dependency.gitHub(.dotCom, Repository(owner: "ExampleOrg", name: "ExamplePrj2"))
		let example3 = Dependency.gitHub(.dotCom, Repository(owner: "ExampleOrg", name: "ExamplePrj3"))
		let example4 = Dependency.gitHub(.dotCom, Repository(owner: "ExampleOrg", name: "ExamplePrj4"))
		
		expect(cartfile.dependencies) == [
			reactiveCocoa: .atLeast(SemanticVersion(2, 3, 1)),
			mantle: .compatibleWith(SemanticVersion(1, 0, 0)),
			libextobjc: .exactly(SemanticVersion(0, 4, 1)),
			xcconfigs: .any,
			iosCharts: .any,
			errorTranslations: .any,
			errorTranslations2: .gitReference("development"),
			example1: .atLeast(SemanticVersion(3, 0, 2, prereleaseIdentifiers: ["pre"])),
			example2: .exactly(SemanticVersion(3, 0, 2, buildMetadataIdentifiers: ["build"])),
			example3: .exactly(SemanticVersion(3, 0, 2)),
			example4: .gitReference("release#2")
		]
	}
	
	func testShouldParseACartfileResolved() {
		guard let testCartfileURL = Bundle(for: type(of: self)).url(forResource: "TestCartfile", withExtension: "resolved") else {
			fail("Could not load TestCartfile.resolved from resources")
			return
		}
		guard let testCartfile = try? String(contentsOf: testCartfileURL, encoding: .utf8) else {
			fail("Could not load Cartfile as string, is it UTF8 encoded?")
			return
		}
		
		let result = ResolvedCartfile.from(string: testCartfile)
		expect(result.error).to(beNil())
		
		guard let resolvedCartfile = result.value else {
			fail("Could not parse resolved cartfile")
			return
		}
		expect(resolvedCartfile.dependencies) == [
			.gitHub(.dotCom, Repository(owner: "ReactiveCocoa", name: "ReactiveCocoa")): PinnedVersion("v2.3.1"),
			.gitHub(.dotCom, Repository(owner: "Mantle", name: "Mantle")): PinnedVersion("40abed6e58b4864afac235c3bb2552e23bc9da47"),
		]
	}
	
	func testShouldDetectDuplicateDependenciesInASingleCartfile() {
		guard let testCartfileURL = Bundle(for: type(of: self)).url(forResource: "DuplicateDependenciesCartfile", withExtension: "") else {
			fail("Could not load DuplicateDependenciesCartfile from resources")
			return
		}
		guard let testCartfile = try? String(contentsOf: testCartfileURL, encoding: .utf8) else {
			fail("Could not load Cartfile as string, is it UTF8 encoded?")
			return
		}
		
		let result = Cartfile.from(string: testCartfile)
		expect(result.error).notTo(beNil())
		
		guard case let .duplicateDependencies(dupes)? = result.error else {
			fail("Cartfile should error with duplicate dependencies")
			return
		}
		
		let dependencies = dupes
			.map { $0.dependency }
			.sorted { $0.description < $1.description }
		expect(dupes.count) == 3
		
		let self2Dupe = dependencies[0]
		expect(self2Dupe) == Dependency.gitHub(.dotCom, Repository(owner: "self2", name: "self2"))
		
		let self3Dupe = dependencies[1]
		expect(self3Dupe) == Dependency.gitHub(.dotCom, Repository(owner: "self3", name: "self3"))
	}
	
	func testShouldDetectDuplicateDependenciesAcrossTwoCartfiles() {
		guard let testCartfileURL = Bundle(for: type(of: self)).url(forResource: "DuplicateDependencies/Cartfile", withExtension: "") else {
			fail("Could not load DuplicateDependencies/Cartfile from resources")
			return
		}
		guard let testCartfile2URL = Bundle(for: type(of: self)).url(forResource: "DuplicateDependencies/Cartfile.private", withExtension: "") else {
			fail("Could not load DuplicateDependencies/Cartfile.private from resources")
			return
		}
		
		guard let testCartfile = try? String(contentsOf: testCartfileURL, encoding: .utf8) else {
			fail("Could not load Cartfile as string, is it UTF8 encoded?")
			return
		}
		guard let testCartfile2 = try? String(contentsOf: testCartfile2URL, encoding: .utf8) else {
			fail("Could not load Cartfile as string, is it UTF8 encoded?")
			return
		}
		
		let result = Cartfile.from(string: testCartfile)
		expect(result.error).to(beNil())
		
		let result2 = Cartfile.from(string: testCartfile2)
		expect(result2.error).to(beNil())
		
		guard let cartfile = result.value else {
			fail("Could not parse Cartfile")
			return
		}
		expect(cartfile.dependencies.count) == 5
		
		guard let cartfile2 = result2.value else {
			fail("Could not parse Cartfile")
			return
		}
		expect(cartfile2.dependencies.count) == 3
		
        let dupes = cartfile.duplicateDependencies(from: cartfile2).sorted { $0.description < $1.description }
		expect(dupes.count) == 3
		
		let dupe1 = dupes[0]
		expect(dupe1) == Dependency.gitHub(.dotCom, Repository(owner: "1", name: "1"))
		
		let dupe3 = dupes[1]
		expect(dupe3) == Dependency.gitHub(.dotCom, Repository(owner: "3", name: "3"))
		
		let dupe5 = dupes[2]
		expect(dupe5) == Dependency.gitHub(.dotCom, Repository(owner: "5", name: "5"))
	}
	
	func testShouldNotAllowABinaryFrameworkWithGitReference() {
		let testCartfile = "binary \"https://server.com/myproject\" \"gitreference\""
		let result = Cartfile.from(string: testCartfile)
		
		expect(result.error) == .parseError(
			description: "binary dependencies cannot have a git reference for the version specifier in line: "
				+ "binary \"https://server.com/myproject\" \"gitreference\""
		)
	}
}

class ResolvedCartfileTests: XCTestCase {
	func testShouldOutputDependenciesAlphabetically() {
		let resolvedCartfile = ResolvedCartfile(dependencies: [
			.gitHub(.dotCom, Repository(owner: "antitypical", name: "Result")): PinnedVersion("3.0.0"),
			.gitHub(.dotCom, Repository(owner: "ReactiveCocoa", name: "ReactiveSwift")): PinnedVersion("v1.0.0"),
			.gitHub(.dotCom, Repository(owner: "ReactiveCocoa", name: "ReactiveCocoa")): PinnedVersion("v2.3.1"),
			])
		
		expect(resolvedCartfile.description) == "github \"ReactiveCocoa/ReactiveCocoa\" \"v2.3.1\"\ngithub \"ReactiveCocoa/ReactiveSwift\" "
			+ "\"v1.0.0\"\ngithub \"antitypical/Result\" \"3.0.0\"\n"
	}
}

class SchemeCartfileTests: XCTestCase {

    func testSchemefileParse() {
        let cartfileString = """
        # Some comment
        c
        b
        a f


        d

        """

        guard let schemeCartfile = SchemeCartfile.from(string: cartfileString).value else {
            XCTFail("Expected scheme cartfile to be parsed successfully")
            return
        }

        XCTAssertEqual(schemeCartfile.schemes, Set(["a f", "b", "c", "d"]))
    }

    func testSchemeCartfileDescription() {

        let schemeCartfile = SchemeCartfile(schemes: ["b", "b", "c", "a"])

        XCTAssertEqual(schemeCartfile.schemes, Set(["a", "b", "c"]))

        expect(schemeCartfile.description) == "a\nb\nc\n"
    }
}
