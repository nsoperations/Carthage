@testable import CarthageKit
import Foundation
import Nimble
import XCTest
import Tentacle

private func testShouldFailWithoutDependency(dependencyType: String) {
    let scanner = Scanner(string: dependencyType)

    let error = Dependency.from(scanner).error

    let expectedError = ScannableError(message: "expected string after dependency type", currentLine: dependencyType)
    expect(error) == expectedError
}

private func testShouldFailWithoutClosingQuoteOnDependency(dependencyType: String) {
    let scanner = Scanner(string: "\(dependencyType) \"dependency")

    let error = Dependency.from(scanner).error

    let expectedError = ScannableError(message: "empty or unterminated string after dependency type", currentLine: "\(dependencyType) \"dependency")
    expect(error) == expectedError
}

private func testShouldFailWithEmptyDependency(dependencyType: String) {
    let scanner = Scanner(string: "\(dependencyType) \" \"")

    let error = Dependency.from(scanner).error

    let expectedError = ScannableError(message: "empty or unterminated string after dependency type", currentLine: "\(dependencyType) \" \"")
    expect(error) == expectedError
}

private func testInvalidDependency(dependencyType: String) {
    testShouldFailWithoutDependency(dependencyType: dependencyType)
    testShouldFailWithoutClosingQuoteOnDependency(dependencyType: dependencyType)
    testShouldFailWithEmptyDependency(dependencyType: dependencyType)
}

class DependencyTests: XCTestCase {
    func testGithubShouldEqualTheNameOfAGithubComRepo() {
        let dependency = Dependency.gitHub(.dotCom, Repository(owner: "owner", name: "name"))

        expect(dependency.name) == "name"
    }

    func testithubShouldEqualTheNameOfAnEnterpriseGithubRepo() {
        let enterpriseRepo = Repository(
            owner: "owner",
            name: "name")

        let dependency = Dependency.gitHub(.enterprise(url: URL(string: "http://server.com")!), enterpriseRepo)

        expect(dependency.name) == "name"
    }

    func testGitShouldBeTheLastComponentOfTheUrl() {
        let dependency = Dependency.git(GitURL("ssh://server.com/myproject"))

        expect(dependency.name) == "myproject"
    }

    func testGitShouldNotIncludeTheTrailingGitSuffix() {
        let dependency = Dependency.git(GitURL("ssh://server.com/myproject.git"))

        expect(dependency.name) == "myproject"
    }

    func testGitShouldBeTheEntireUrlStringIfThereIsNoLastComponent() {
        let dependency = Dependency.git(GitURL("whatisthisurleven"))

        expect(dependency.name) == "whatisthisurleven"
    }

    func testBinaryShouldBeTheLastComponentOfTheUrl() {
        let url = URL(string: "https://server.com/myproject")!
        let binary = BinaryURL(url: url, resolvedDescription: url.description)
        let dependency = Dependency.binary(binary)

        expect(dependency.name) == "myproject"
    }

    func testBinaryShouldNotIncludeTheTrailingGitSuffix() {
        let url = URL(string: "https://server.com/myproject.json")!
        let binary = BinaryURL(url: url, resolvedDescription: url.description)
        let dependency = Dependency.binary(binary)

        expect(dependency.name) == "myproject"
    }

    func testGithubShouldReadAGithubComDependency() {
        let scanner = Scanner(string: "github \"ReactiveCocoa/ReactiveCocoa\"")

        let dependency = Dependency.from(scanner).value

        let expectedRepo = Repository(owner: "ReactiveCocoa", name: "ReactiveCocoa")
        expect(dependency) == .gitHub(.dotCom, expectedRepo)
    }

    func testGithubShouldReadAGithubComDependencyWithFullUrl() {
        let scanner = Scanner(string: "github \"https://github.com/ReactiveCocoa/ReactiveCocoa\"")

        let dependency = Dependency.from(scanner).value

        let expectedRepo = Repository(owner: "ReactiveCocoa", name: "ReactiveCocoa")
        expect(dependency) == .gitHub(.dotCom, expectedRepo)
    }

    func testGithubShouldReadAnEnterpriseGithubDependency() {
        let scanner = Scanner(string: "github \"http://mysupercoolinternalwebhost.com/ReactiveCocoa/ReactiveCocoa\"")

        let dependency = Dependency.from(scanner).value

        let expectedRepo = Repository(
            owner: "ReactiveCocoa",
            name: "ReactiveCocoa"
        )
        expect(dependency) == .gitHub(.enterprise(url: URL(string: "http://mysupercoolinternalwebhost.com")!), expectedRepo)
    }

    func testGithubShouldFailWithInvalidGithubComDependency() {
        let scanner = Scanner(string: "github \"Whatsthis\"")

        let error = Dependency.from(scanner).error

        let expectedError = ScannableError(message: "invalid GitHub repository identifier \"Whatsthis\"")
        expect(error) == expectedError
    }

    func testGithubShouldFailWithInvalidEnterpriseGithubDependency() {
        let scanner = Scanner(string: "github \"http://mysupercoolinternalwebhost.com/ReactiveCocoa\"")

        let error = Dependency.from(scanner).error

        let expectedError = ScannableError(message: "invalid GitHub repository identifier \"http://mysupercoolinternalwebhost.com/ReactiveCocoa\"")
        expect(error) == expectedError
    }

    func testGithubInvalidDependency() {
        testInvalidDependency(dependencyType: "github")
    }

    func testGitShouldReadAGitUrl() {
        let scanner = Scanner(string: "git \"mygiturl\"")

        let dependency = Dependency.from(scanner).value

        expect(dependency) == .git(GitURL("mygiturl"))
    }

    func testGitShouldReadAGitDependencyAsGithub1() {
        let scanner = Scanner(string: "git \"ssh://git@github.com:owner/name\"")

        let dependency = Dependency.from(scanner).value

        let expectedRepo = Repository(owner: "owner", name: "name")

        expect(dependency) == .gitHub(.dotCom, expectedRepo)
    }

    func testGitShouldReadAGitDependencyAsGithub2() {
        let scanner = Scanner(string: "git \"https://github.com/owner/name\"")

        let dependency = Dependency.from(scanner).value

        let expectedRepo = Repository(owner: "owner", name: "name")

        expect(dependency) == .gitHub(.dotCom, expectedRepo)
    }

    func testGitShouldReadAGitDependencyAsGithub3() {
        let scanner = Scanner(string: "git \"git@github.com:owner/name\"")

        let dependency = Dependency.from(scanner).value

        let expectedRepo = Repository(owner: "owner", name: "name")

        expect(dependency) == .gitHub(.dotCom, expectedRepo)
    }

    func testGitInvalidDependency() {
        testInvalidDependency(dependencyType: "git")
    }

    func testBinaryShouldReadAUrlWithHttpsScheme() {
        let scanner = Scanner(string: "binary \"https://mysupercoolinternalwebhost.com/\"")

        let dependency = Dependency.from(scanner).value
        let url = URL(string: "https://mysupercoolinternalwebhost.com/")!
        let binary = BinaryURL(url: url, resolvedDescription: url.description)

        expect(dependency) == .binary(binary)
    }

    func testBinaryShouldReadAUrlWithFileScheme() {
        let scanner = Scanner(string: "binary \"file:///my/domain/com/framework.json\"")

        let dependency = Dependency.from(scanner).value
        let url = URL(string: "file:///my/domain/com/framework.json")!
        let binary = BinaryURL(url: url, resolvedDescription: url.description)

        expect(dependency) == .binary(binary)
    }

    func testBinaryShouldReadAUrlWithRelativeFilePath() {
        let relativePath = "my/relative/path/framework.json"
        let scanner = Scanner(string: "binary \"\(relativePath)\"")

        let workingDirectory = URL(string: "file:///current/working/directory/")!
        let dependency = Dependency.from(scanner, base: workingDirectory).value

        let url = URL(string: "file:///current/working/directory/my/relative/path/framework.json")!
        let binary = BinaryURL(url: url, resolvedDescription: relativePath)

        expect(dependency) == .binary(binary)
    }

    func testBinaryShouldReadAUrlWithAnAbsolutePath() {
        let absolutePath = "/my/absolute/path/framework.json"
        let scanner = Scanner(string: "binary \"\(absolutePath)\"")

        let dependency = Dependency.from(scanner).value
        let url = URL(string: "file:///my/absolute/path/framework.json")!
        let binary = BinaryURL(url: url, resolvedDescription: absolutePath)

        expect(dependency) == .binary(binary)
    }

    func testBinaryShouldFailWithInvalidUrl() {
        let scanner = Scanner(string: "binary \"nop@%@#^@e\"")

        let error = Dependency.from(scanner).error

        expect(error) == ScannableError(message: "invalid URL found for dependency type `binary`", currentLine: "binary \"nop@%@#^@e\"")
    }

    func testBinaryInvalidDependency() {
        testInvalidDependency(dependencyType: "binary")
    }
}
