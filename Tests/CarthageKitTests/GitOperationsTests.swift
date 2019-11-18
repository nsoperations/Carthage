import Foundation
import Nimble
@testable import CarthageKit
import ReactiveSwift
import XCTest
import ReactiveTask

class GitOperationsTests: XCTestCase {

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

    func testShouldFetchAProjectIfTheGivenCommitishExistsButThatIsNotAReference() {
        // Clone first
        let commitish = addCommit()
        expect(self.cloneOrFetch().wait().error).to(beNil())

        addCommit()

        assertProjectEvent(commitish: commitish) { expect($0?.isFetching) == true }
    }

    func testShouldNotFetchTwiceInARowEvenIfNoCommitishIsGiven() {
        // Clone first
        expect(self.cloneOrFetch().wait().error).to(beNil())

        assertProjectEvent { expect($0?.isFetching) == true }
        assertProjectEvent(clearFetchTime: false) { expect($0).to(beNil()) }
    }
}
