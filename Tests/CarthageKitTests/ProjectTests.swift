@testable import CarthageKit
import Foundation
import Nimble
import XCTest
import ReactiveSwift
import Tentacle
import Result
import ReactiveTask
import XCDBLD

// swiftlint:disable:this force_try

private enum ProjectTestsError: Error {
    case assertion(message: String)
}

class ProjectBuildTests: XCTestCase {
    var directoryURL: URL!
    var buildDirectoryURL: URL!
    var noSharedSchemesDirectoryURL: URL!
    var noSharedSchemesBuildDirectoryURL: URL!

    func build(directoryURL url: URL, platforms: Set<Platform> = [], cacheBuilds: Bool = true, useBinaries: Bool = false, dependenciesToBuild: [String]? = nil, configuration: String = "Debug") -> [String] {
        let project = Project(directoryURL: url)
        guard let result = project.buildCheckedOutDependenciesWithOptions(BuildOptions(configuration: configuration, platforms: platforms, cacheBuilds: cacheBuilds, useBinaries: useBinaries), dependenciesToBuild: dependenciesToBuild)
            .ignoreTaskData()
            .on(value: { project, scheme in
                NSLog("Building scheme \"\(scheme)\" in \(project)")
            })
            .map({ _, scheme in scheme })
            .collect()
            .single() else {

                fail("Could not build scheme")
                return [String]()
        }
        expect(result.error).to(beNil())

        guard let resultValue = result.value else {
            fail("No result found")
            return [String]()
        }

        return resultValue.map { $0.name }
    }

    func buildDependencyTest(platforms: Set<Platform> = [], cacheBuilds: Bool = true, dependenciesToBuild: [String]? = nil, configuration: String = "Debug") -> [String] {
        return build(directoryURL: directoryURL, platforms: platforms, cacheBuilds: cacheBuilds, dependenciesToBuild: dependenciesToBuild, configuration: configuration)
    }

    func buildNoSharedSchemesTest(platforms: Set<Platform> = [], cacheBuilds: Bool = true, dependenciesToBuild: [String]? = nil) -> [String] {
        return build(directoryURL: noSharedSchemesDirectoryURL, platforms: platforms, cacheBuilds: cacheBuilds, dependenciesToBuild: dependenciesToBuild)
    }

    override func setUp() {
        guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "DependencyTest", withExtension: nil) else {
            fail("Could not load DependencyTest from resources")
            return
        }
        self.directoryURL = directoryURL
        buildDirectoryURL = directoryURL.appendingPathComponent(Constants.binariesFolderPath)

        guard let noSharedSchemesDirectoryURL = Bundle(for: type(of: self)).url(forResource: "NoSharedSchemesTest", withExtension: nil) else {
            fail("Could not load NoSharedSchemesTest from resources")
            return
        }
        self.noSharedSchemesDirectoryURL = noSharedSchemesDirectoryURL
        noSharedSchemesBuildDirectoryURL = noSharedSchemesDirectoryURL.appendingPathComponent(Constants.binariesFolderPath)
        _ = try? FileManager.default.removeItem(at: buildDirectoryURL)
        // Pre-fetch the repos so we have a cache for the given tags
        let sourceRepoUrl = directoryURL.appendingPathComponent("SourceRepos")
        for repo in ["TestFramework1", "TestFramework2", "TestFramework3"] {
            let urlPath = sourceRepoUrl.appendingPathComponent(repo).path
            _ = ProjectDependencyRetriever.cloneOrFetch(dependency: .git(GitURL(urlPath)), preferHTTPS: false)
                .wait()
        }
    }

    func testShouldBuildFrameworksInTheCorrectOrder() {
        let macOSexpected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]
        let iOSExpected = ["TestFramework3_iOS", "TestFramework2_iOS", "TestFramework1_iOS"]

        let result = buildDependencyTest(platforms: [], cacheBuilds: false)

        expect(result.filter { $0.contains("Mac") }) == macOSexpected
        expect(result.filter { $0.contains("iOS") }) == iOSExpected
        expect(Set(result)) == Set<String>(macOSexpected + iOSExpected)
    }

    func testShouldDetermineBuildOrderWithoutRepoCache() {
        let macOSexpected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]
        for dep in ["TestFramework3", "TestFramework2", "TestFramework1"] {
            _ = try? FileManager.default.removeItem(at: Constants.Dependency.repositoriesURL.appendingPathComponent(dep))
        }
        // Without the repo cache, it won't know to build frameworks 2 and 3 unless it reads the Cartfile from the checkout directory
        let result = buildDependencyTest(platforms: [.macOS], cacheBuilds: false, dependenciesToBuild: ["TestFramework1"])
        expect(result) == macOSexpected
    }

    func testShouldFallBackToRepoCacheIfCheckoutIsMissing() {
        let macOSexpected = ["TestFramework3_Mac", "TestFramework2_Mac"]
        let repoDir = directoryURL.appendingPathComponent(Constants.checkoutsPath)
        let checkout = repoDir.appendingPathComponent("TestFramework1")
        let tmpCheckout = repoDir.appendingPathComponent("TestFramework1_BACKUP")
        do {
            try FileManager.default.moveItem(at: checkout, to: tmpCheckout)
        } catch {
            fail("Could not move checkout to tmpCheckout: \(error)")
            return
        }

        // Without the checkout, it should still figure out it needs to build 2 and 3.
        let result = buildDependencyTest(platforms: [.macOS], cacheBuilds: false)
        expect(result) == macOSexpected
        do {
            try FileManager.default.moveItem(at: tmpCheckout, to: checkout)
        } catch {
            fail("Could not move tmpCheckout to checkout: \(error)")
            return
        }
    }

    func overwriteFramework(_ frameworkName: String, forPlatformName platformName: String, inDirectory buildDirectoryURL: URL) throws {
        let platformURL = buildDirectoryURL.appendingPathComponent(platformName, isDirectory: true)
        let frameworkURL = platformURL.appendingPathComponent("\(frameworkName).framework", isDirectory: false)
        let binaryURL = frameworkURL.appendingPathComponent("\(frameworkName)", isDirectory: false)

        let data = "junkdata".data(using: .utf8)!
        try data.write(to: binaryURL, options: .atomic)
    }

    func overwriteSwiftVersion(
        _ frameworkName: String,
        forPlatformName platformName: String,
        inDirectory buildDirectoryURL: URL,
        withVersion version: (String, String)) throws
    {
        let platformURL = buildDirectoryURL.appendingPathComponent(platformName, isDirectory: true)
        let frameworkURL = platformURL.appendingPathComponent("\(frameworkName).framework", isDirectory: false)
        guard let swiftHeaderURL = frameworkURL.swiftHeaderURL() else {
            throw ProjectTestsError.assertion(message: "Could not get Swift header URL")
        }

        var header = try String(contentsOf: swiftHeaderURL)
        
        guard
            let match = SwiftToolchain.swiftVersionRegex.firstMatch(in: header, options: [], range: NSRange(header.startIndex..., in: header)),
            match.numberOfRanges == 3
            else
        {
            throw ProjectTestsError.assertion(message: "Could not parse swift version from header")
        }
        
        let first = Range(match.range(at: 1), in: header)!
        let second = Range(match.range(at: 2), in: header)!
        
        header.replaceSubrange(first, with: version.0)
        header.replaceSubrange(second, with: version.1)
        
        try header.write(to: swiftHeaderURL, atomically: true, encoding: header.fastestEncoding)
    }

    func removeDsym(
        _ frameworkName: String,
        forPlatformName platformName: String,
        inDirectory buildDirectoryURL: URL) -> Bool
    {
        let platformURL = buildDirectoryURL.appendingPathComponent(platformName, isDirectory: true)
        let dSYMURL = platformURL
            .appendingPathComponent("\(frameworkName).framework.dSYM", isDirectory: true)

        do {
            try FileManager.default.removeItem(at: dSYMURL)
            return true
        }
        catch {
            return false
        }
    }

    func testShouldNotRebuildCachedFrameworksUnlessInstructedToIgnoreCachedBuilds() {
        let expected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]

        let result1 = buildDependencyTest(platforms: [.macOS])
        expect(result1) == expected

        let result2 = buildDependencyTest(platforms: [.macOS])
        expect(result2) == []

        let result3 = buildDependencyTest(platforms: [.macOS], cacheBuilds: false)
        expect(result3) == expected
    }

    func testShouldRebuildCachedFrameworksAndDependenciesWhoseHashDoesNotMatchTheVersionFile() {
        let expected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]

        let result1 = buildDependencyTest(platforms: [.macOS])
        expect(result1) == expected

        do {
            try overwriteFramework("TestFramework3", forPlatformName: "Mac", inDirectory: buildDirectoryURL)
        } catch {
            fail("Could not overwrite framework: \(error)")
            return
        }

        let result2 = buildDependencyTest(platforms: [.macOS])
        expect(result2) == expected
    }
    
    func testShouldRebuildCachedFrameworksAndDependenciesIfBuildConfigurationIsDifferent() {
        let expected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]
        
        let result1 = buildDependencyTest(platforms: [.macOS], configuration: "Debug")
        expect(result1) == expected
        
        let result2 = buildDependencyTest(platforms: [.macOS], configuration: "Release")
        expect(result2) == expected
    }

    func testShouldRebuildCachedFrameworksAndDependenciesWhoseVersionDoesNotMatchTheVersionFile() {
        let expected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]

        let result1 = buildDependencyTest(platforms: [.macOS])
        expect(result1) == expected

        let preludeVersionFileURL = buildDirectoryURL.appendingPathComponent(".TestFramework3.version", isDirectory: false)
        let preludeVersionFilePath = preludeVersionFileURL.path

        guard let json = try? String(contentsOf: preludeVersionFileURL, encoding: .utf8) else {
            fail("Could not load preludeVersionFile")
            return
        }
        let modifiedJson = json.replacingOccurrences(of: "\"commitish\" : \"v1.0\"", with: "\"commitish\" : \"v1.1\"")
        do {
            _ = try modifiedJson.write(toFile: preludeVersionFilePath, atomically: true, encoding: .utf8)
        } catch {
            fail("Could not write modified json to file: \(error)")
            return
        }

        let result2 = buildDependencyTest(platforms: [.macOS])
        expect(result2) == expected
    }

    func testShouldRebuildCachedFrameworksAndDependenciesWhoseSwiftVersionDoesNotMatchTheLocalSwiftVersion() {
        let expected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]

        let result1 = buildDependencyTest(platforms: [.macOS])
        expect(result1) == expected

        do {
            try overwriteSwiftVersion("TestFramework3",
                                      forPlatformName: "Mac",
                                      inDirectory: buildDirectoryURL,
                                      withVersion: ("1.0", "swiftlang-000.0.1 clang-000.0.0.1"))
        } catch {
            fail("Could not overwrite swift version: \(error)")
            return
        }

        let allDSymsRemoved = expected
            .compactMap { removeDsym($0.dropLast(4).description, forPlatformName: "Mac", inDirectory: buildDirectoryURL) }
            .reduce(true) { acc, next in return  acc && next }
        expect(allDSymsRemoved) == true

        let result2 = buildDependencyTest(platforms: [.macOS])
        expect(result2) == expected
    }

    func testShouldNotRebuildCachedFrameworksUnnecessarily() {
        let expected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]

        let result1 = buildDependencyTest(platforms: [.macOS])
        expect(result1) == expected

        do {
            try overwriteFramework("TestFramework2", forPlatformName: "Mac", inDirectory: buildDirectoryURL)
        } catch {
            fail("Could not overwrite framework: \(error)")
            return
        }

        let result2 = buildDependencyTest(platforms: [.macOS])
        expect(result2) == ["TestFramework2_Mac", "TestFramework1_Mac"]
    }

    func testShouldRebuildCachedFrameworksAndDependenciesEvenIfDsymsDidNotChange() {
        let expected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]

        let result1 = buildDependencyTest(platforms: [.macOS])
        expect(result1) == expected

        // Overwrite one header, this should trigger cheking the dSYM instead
        do {
            try overwriteSwiftVersion("TestFramework3",
                                      forPlatformName: "Mac",
                                      inDirectory: buildDirectoryURL,
                                      withVersion: ("1.0", "swiftlang-000.0.1 clang-000.0.0.1"))
        } catch {
            fail("Could not overwrite swift version: \(error)")
            return
        }

        let result2 = buildDependencyTest(platforms: [.macOS])
        expect(result2) == expected
    }

    func testShouldRebuildAFrameworkForAllPlatformsEvenACachedFrameworkIsInvalidForOnlyASinglePlatform() {
        let macOSexpected = ["TestFramework3_Mac", "TestFramework2_Mac", "TestFramework1_Mac"]
        let iOSExpected = ["TestFramework3_iOS", "TestFramework2_iOS", "TestFramework1_iOS"]

        let result1 = buildDependencyTest()
        expect(result1.filter { $0.contains("Mac") }) == macOSexpected
        expect(result1.filter { $0.contains("iOS") }) == iOSExpected
        expect(Set(result1)) == Set<String>(macOSexpected + iOSExpected)

        do {
            try overwriteFramework("TestFramework1", forPlatformName: "Mac", inDirectory: buildDirectoryURL)
        } catch {
            fail("Could not overwrite framework: \(error)")
            return
        }

        let result2 = buildDependencyTest()
        expect(result2.filter { $0.contains("Mac") }) == ["TestFramework1_Mac"]
        expect(result2.filter { $0.contains("iOS") }) == ["TestFramework1_iOS"]
    }

    func testShouldCreateAndReadAVersionFileForAProjectWithNoSharedSchemes() {
        let result = buildNoSharedSchemesTest(platforms: [.iOS])
        expect(result) == ["TestFramework1_iOS"]

        let result2 = buildNoSharedSchemesTest(platforms: [.iOS])
        expect(result2) == []

        // TestFramework2 has no shared schemes, but invalidating its version file should result in its dependencies (TestFramework1) being rebuilt
        let framework2VersionFileURL = noSharedSchemesBuildDirectoryURL.appendingPathComponent(".TestFramework2.version", isDirectory: false)
        let framework2VersionFilePath = framework2VersionFileURL.path

        guard let json = try? String(contentsOf: framework2VersionFileURL, encoding: .utf8) else {
            fail("Could not load framework version file")
            return
        }
        let modifiedJson = json.replacingOccurrences(of: "\"commitish\" : \"v1.0\"", with: "\"commitish\" : \"v1.1\"")
        do {
            _ = try modifiedJson.write(toFile: framework2VersionFilePath, atomically: true, encoding: .utf8)
        } catch {
            fail("Could not write modified json file: \(error)")
            return
        }

        let result3 = buildNoSharedSchemesTest(platforms: [.iOS])
        expect(result3) == ["TestFramework1_iOS"]
    }
}

class ProjectCartfileTests: XCTestCase {

    func testShouldLoadACombinedCartfileWhenOnlyACartfileIsPresent() {
        guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "CartfileOnly", withExtension: nil) else {
            fail("Could not lead CartfileOnly from resources")
            return
        }
        let result = Project(directoryURL: directoryURL).loadCombinedCartfile().single()
        expect(result).notTo(beNil())
        expect(result?.value).notTo(beNil())

        let dependencies = result?.value?.dependencies
        expect(dependencies?.count) == 1
        expect(dependencies?.keys.first?.name) == "Carthage"
    }

    func testShouldLoadACombinedCartfileWhenOnlyACartfilePrivateIsPresent() {
        guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "CartfilePrivateOnly", withExtension: nil) else {
            fail("Could not load CartfilePrivateOnly from resources")
            return
        }
        let result = Project(directoryURL: directoryURL).loadCombinedCartfile().single()
        expect(result).notTo(beNil())
        expect(result?.value).notTo(beNil())

        let dependencies = result?.value?.dependencies
        expect(dependencies?.count) == 1
        expect(dependencies?.keys.first?.name) == "Carthage"
    }

    func testShouldDetectDuplicateDependenciesAcrossCartfileAndCartfilePrivate() {
        guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "DuplicateDependencies", withExtension: nil) else {
            fail("Could not load DuplicateDependencies from resources")
            return
        }
        let result = Project(directoryURL: directoryURL).loadCombinedCartfile().single()
        expect(result).notTo(beNil())

        let resultError = result?.error
        expect(resultError).notTo(beNil())

        let makeDependency: (String, String, [String]) -> DuplicateDependency = { repoOwner, repoName, locations in
            let dependency = Dependency.gitHub(.dotCom, Repository(owner: repoOwner, name: repoName))
            return DuplicateDependency(dependency: dependency, locations: locations)
        }

        let locations = ["\(Constants.Project.cartfilePath)", "\(Constants.Project.privateCartfilePath)"]

        let expectedError = CarthageError.duplicateDependencies([
            makeDependency("1", "1", locations),
            makeDependency("3", "3", locations),
            makeDependency("5", "5", locations),
            ])

        expect(resultError) == expectedError
    }

    func testShouldErrorWhenNeitherACartfileNorACartfilePrivateExists() {
        guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "NoCartfile", withExtension: nil) else {
            fail("Could not load NoCartfile from resources")
            return
        }
        let result = Project(directoryURL: directoryURL).loadCombinedCartfile().single()
        expect(result).notTo(beNil())

        if case let .readFailed(_, underlyingError)? = result?.error {
            expect(underlyingError?.domain) == NSCocoaErrorDomain
            expect(underlyingError?.code) == NSFileReadNoSuchFileError
        } else {
            fail()
        }
    }
}

class ProjectGitOperationsTests: XCTestCase {

    var temporaryPath: String!
    var temporaryURL: URL!
    var repositoryURL: URL!
    var cacheDirectoryURL: URL!
    var dependency: Dependency!

    func initRepository() {
        expect { try FileManager.default.createDirectory(atPath: self.repositoryURL.path, withIntermediateDirectories: true) }.notTo(throwError())
        _ = Git.launchGitTask([ "init" ], repositoryFileURL: repositoryURL).wait()
    }

    @discardableResult
    func addCommit() -> String {
        _ = Git.launchGitTask([ "commit", "--allow-empty", "-m \"Empty commit\"" ], repositoryFileURL: repositoryURL).wait()
        guard let commit = Git.launchGitTask([ "rev-parse", "--short", "HEAD" ], repositoryFileURL: repositoryURL)
            .last()?
            .value?
            .trimmingCharacters(in: .newlines) else {
                fail("Could not get commit")
                return ""
        }
        return commit
    }

    func cloneOrFetch(commitish: String? = nil) -> SignalProducer<(ProjectEvent?, URL), CarthageError> {
        return CarthageKit.ProjectDependencyRetriever.cloneOrFetch(dependency: dependency, preferHTTPS: false, destinationURL: cacheDirectoryURL, commitish: commitish)
    }

    func assertProjectEvent(commitish: String? = nil, clearFetchTime: Bool = true, file: String = #file, line: Int = #line, action: @escaping (ProjectEvent?) -> Void) {
        waitUntil { done in
            if clearFetchTime {
                Git.FetchCache.clearFetchTimes()
            }
            self.cloneOrFetch(commitish: commitish).start(Signal.Observer(
                value: { event, _ in action(event) },
                completed: done
            ))
        }
    }

    override func setUp() {
        // https://github.com/Carthage/Carthage/issues/1191
        temporaryPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        temporaryURL = URL(fileURLWithPath: temporaryPath, isDirectory: true)
        repositoryURL = temporaryURL.appendingPathComponent("carthage1191", isDirectory: true)
        cacheDirectoryURL = temporaryURL.appendingPathComponent("cache", isDirectory: true)
        dependency = Dependency.git(GitURL(repositoryURL.absoluteString))
        expect { try FileManager.default.createDirectory(atPath: self.temporaryURL.path, withIntermediateDirectories: true) }.notTo(throwError())
        initRepository()
    }

    override func tearDown() {
        _ = try? FileManager.default.removeItem(at: temporaryURL)
    }

    func testShouldCloneAProjectIfItIsNotClonedYet() {
        assertProjectEvent { expect($0?.isCloning) == true }
    }

    func testShouldFetchAProjectIfNoCommitishIsGiven() {
        // Clone first
        expect(self.cloneOrFetch().wait().error).to(beNil())

        assertProjectEvent { expect($0?.isFetching) == true }
    }

    func testShouldFetchAProjectIfTheGivenCommitishDoesNotExistInTheClonedRepository() {
        // Clone first
        addCommit()
        expect(self.cloneOrFetch().wait().error).to(beNil())

        let commitish = addCommit()

        assertProjectEvent(commitish: commitish) { expect($0?.isFetching) == true }
    }

    func testShouldFetchAProjectIfTheGivenCommitishExistsButThatIsAReference() {
        // Clone first
        addCommit()
        expect(self.cloneOrFetch().wait().error).to(beNil())

        addCommit()

        assertProjectEvent(commitish: "master") { expect($0?.isFetching) == true }
    }

    func testShouldNotFetchAProjectIfTheGivenCommitishExistsButThatIsNotAReference() {
        // Clone first
        let commitish = addCommit()
        expect(self.cloneOrFetch().wait().error).to(beNil())

        addCommit()

        assertProjectEvent(commitish: commitish) { expect($0).to(beNil()) }
    }

    func testShouldNotFetchTwiceInARowEvenIfNoCommitishIsGiven() {
        // Clone first
        expect(self.cloneOrFetch().wait().error).to(beNil())

        assertProjectEvent { expect($0?.isFetching) == true }
        assertProjectEvent(clearFetchTime: false) { expect($0).to(beNil()) }
    }
}

class ProjectFrameworkDefinitionTests: XCTestCase {
    var project: Project!
    var testDefinitionURL: URL!
    override func setUp() {
        guard let nonNilURL = Bundle(for: type(of: self)).url(forResource: "BinaryOnly/successful", withExtension: "json") else {
            fail("Could not load BinaryOnly/successful.json from resources")
            return
        }
        testDefinitionURL = nonNilURL
        project = Project(directoryURL: URL(string: "file:///var/empty/fake")!)
    }

    func testShouldReturnDefinition() {
        let binary = BinaryURL(url: testDefinitionURL, resolvedDescription: testDefinitionURL.description)
        let actualDefinition = project.dependencyRetriever.downloadBinaryFrameworkDefinition(binary: binary).first()?.value

        let expectedBinaryProject = BinaryProject(urls: [
            PinnedVersion("1.0"): URL(string: "https://my.domain.com/release/1.0.0/framework.zip")!,
            PinnedVersion("1.0.1"): URL(string: "https://my.domain.com/release/1.0.1/framework.zip")!,
            ])
        expect(actualDefinition) == expectedBinaryProject
    }

    func testShouldReturnReadFailedIfUnableToDownload() {
        let url = URL(string: "file:///thisfiledoesnotexist.json")!
        let binary = BinaryURL(url: url, resolvedDescription: testDefinitionURL.description)
        let actualError = project.dependencyRetriever.downloadBinaryFrameworkDefinition(binary: binary).first()?.error

        switch actualError {
        case .some(.readFailed):
            break

        default:
            fail("expected read failed error")
        }
    }

    func testShouldReturnAnInvalidBinaryJsonErrorIfUnableToParseFile() {
        guard let invalidDependencyURL = Bundle(for: type(of: self)).url(forResource: "BinaryOnly/invalid", withExtension: "json") else {
            fail("Could not load BinaryOnly/invalid.json from resources")
            return
        }
        let binary = BinaryURL(url: invalidDependencyURL, resolvedDescription: invalidDependencyURL.description)

        let actualError = project.dependencyRetriever.downloadBinaryFrameworkDefinition(binary: binary).first()?.error

        switch actualError {
        case .some(CarthageError.invalidBinaryJSON(invalidDependencyURL, BinaryJSONError.invalidJSON)):
            break

        default:
            fail("expected invalid binary JSON error")
        }
    }

    func testShouldBroadcastDownloadingFrameworkDefinitionEvent() {
        var events = [ProjectEvent]()
        project.projectEvents.observeValues { events.append($0) }

        let binary = BinaryURL(url: testDefinitionURL, resolvedDescription: testDefinitionURL.description)
        _ = project.dependencyRetriever.downloadBinaryFrameworkDefinition(binary: binary).first()

        expect(events) == [.downloadingBinaryFrameworkDefinition(.binary(binary), testDefinitionURL)]
    }
}

class ProjectMiscTests: XCTestCase {

    func testShouldReturnReturnAvailableUpdatesForOutdatedDependencies() {
        var db: DB = [
            github1: [
                .v1_0_0: [:]
            ],
            github2: [
                .v1_0_0: [:],
                .v1_1_0: [:],
                .v2_0_0: [:]
            ],
            github3: [
                .v1_0_0: [:],
                .v1_1_0: [:],
                .v1_2_0: [:],
                .v2_0_0: [:],
                .v2_0_1: [:]
            ],
            github4: [
                .v1_0_0: [:],
                .v1_2_0: [:],
                .v3_0_0_beta_1: [:],
                .v3_0_0: [:]
            ],
            github5: [
                .v1_0_0: [:]
            ],
            github6: [
                .v1_0_0: [:]
            ]
        ]
        let currentSHA = "2ea246ae4573538886ffb946d70d141583443734"
        let nextSHA = "809b8eb20f4b6b9e805b62de3084fbc7fcde54cc"
        db.references = [
            github3: [
                "2.0": PinnedVersion("v2.0.1")
            ],
            github4: [
                "2.0": PinnedVersion("v2.0.1")
            ],
            github5: [
                "development": PinnedVersion(currentSHA)
            ],
            github6: [
                "development": PinnedVersion(nextSHA)
            ]
        ]
        guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "OutdatedDependencies", withExtension: nil) else {
            fail("Could not load OutdatedDependencies from resources")
            return
        }
        let project = Project(directoryURL: directoryURL)

        guard let result = project.outdatedDependencies(false, resolver: db.resolver()).single() else {
            fail("Expected result to not be nil")
            return
        }
        expect(result).notTo(beNil())
        expect(result.error).to(beNil())
        expect(result.value).notTo(beNil())

        guard let outdatedDependencies = result.value?.reduce(into: [:], { (result, next) in
            result[next.0] = (next.1, next.2, next.3)
        }) else {
            fail("Expected value to not be nil")
            return
        }

        // Github 1 has no updates available
        expect(outdatedDependencies[github1]).to(beNil())

        // Github 2 is currently at 1.0.0, can be updated to the latest version which is 2.0.0
        // Github 2 has no constraint in the Cartfile
        expect(outdatedDependencies[github2]?.0) == PinnedVersion("v1.0.0")
        expect(outdatedDependencies[github2]?.1) == PinnedVersion("v2.0.0")
        expect(outdatedDependencies[github2]?.2) == PinnedVersion("v2.0.0")

        // Github 3 is currently at 2.0.0, latest is 2.0.1, to which it can be updated
        // Github 3 has a constraint in the Cartfile
        expect(outdatedDependencies[github3]?.0) == PinnedVersion("v2.0.0")
        expect(outdatedDependencies[github3]?.1) == PinnedVersion("v2.0.1")
        expect(outdatedDependencies[github3]?.2) == PinnedVersion("v2.0.1")

        // Github 4 is currently at 2.0.0, latest is 3.0.0, but it can only be updated to 2.0.1
        expect(outdatedDependencies[github4]?.0) == PinnedVersion("v2.0.0")
        expect(outdatedDependencies[github4]?.1) == PinnedVersion("v2.0.1")
        expect(outdatedDependencies[github4]?.2) == PinnedVersion("v3.0.0")

        // Github 5 is pinned to a branch and is already at the most recent commit, so it should not be displayed
        expect(outdatedDependencies[github5]).to(beNil())

        // Github 6 is pinned ot a branch which has new commits, so it should be displayed
        expect(outdatedDependencies[github6]?.0) == PinnedVersion(currentSHA)
        expect(outdatedDependencies[github6]?.1) == PinnedVersion(nextSHA)
        expect(outdatedDependencies[github6]?.2) == PinnedVersion("v1.0.0")
    }

    // Checks the framework's executable binary, not the Info.plist.
    // The Info.plist is missing from Alamofire's bundle on purpose.
    func testShouldCheckTheFrameworksExecutableBinaryAndProduceAPlatform() {
        guard let testStaticFrameworkURL = Bundle(for: type(of: self)).url(forResource: "Alamofire.framework", withExtension: nil) else {
            fail("Could not load Alomfire.framework from resources")
            return
        }
        let actualPlatform = Frameworks.platformForFramework(testStaticFrameworkURL).first()?.value
        expect(actualPlatform) == .iOS
    }

    func testShouldFindTheCorrectDependencies() {
        let cartfile = """
                github "Alamofire/Alamofire" "4.6.0"
                github "CocoaLumberjack/CocoaLumberjack" "3.4.1"
                github "Moya/Moya" "10.0.2"
                github "ReactiveCocoa/ReactiveSwift" "2.0.1"
                github "ReactiveX/RxSwift" "4.1.2"
                github "antitypical/Result" "3.2.4"
                github "yapstudios/YapDatabase" "3.0.2"
                """

        let resolvedCartfile = ResolvedCartfile.from(string: cartfile)
        let project = Project(directoryURL: URL(string: "file:///var/empty/fake")!)

        guard let resolvedCartfileValue = resolvedCartfile.value else {
            fail("Expected ResolvedCartfile value to not be nil")
            return
        }

        let result = project.dependencyRetriever.transitiveDependencies(resolvedCartfile: resolvedCartfileValue, includedDependencyNames: ["Moya"]).single()

        expect(result?.value).to(contain("Alamofire"))
        expect(result?.value).to(contain("ReactiveSwift"))
        expect(result?.value).to(contain("Result"))
        expect(result?.value).to(contain("RxSwift"))
        expect(result?.value?.count) == 4
    }

    func testShouldFindAllCarthageCompatibleFrameworkBundlesAndExcludeImproperOnes() {
        guard let directoryURL = Bundle(for: type(of: self)).url(forResource: "FilterBogusFrameworks", withExtension: nil) else {
            fail("Could not load FilterBogusFrameworks from resources")
            return
        }

        let result = Frameworks.frameworksInDirectory(directoryURL).collect().single()
        expect(result?.value?.count) == 3
    }
}

extension ProjectEvent {
    fileprivate var isCloning: Bool {
        if case .cloning = self {
            return true
        }
        return false
    }

    fileprivate var isFetching: Bool {
        if case .fetching = self {
            return true
        }
        return false
    }
}

private func ==<A: Equatable, B: Equatable>(lhs: [(A, B)], rhs: [(A, B)]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (lhs, rhs) in zip(lhs, rhs) {
        guard lhs == rhs else { return false }
    }
    return true
}
