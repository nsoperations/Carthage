@testable import CarthageKit
import Foundation
import Nimble
import XCTest
import ReactiveSwift
import Result
import Tentacle

private extension CarthageError {
    var compatibilityInfos: [CompatibilityInfo] {
        if case let .invalidResolvedCartfile(infos) = self {
            return infos
        }
        return []
    }
}

class ValidateTests: XCTestCase {

    var validCartfile: String!
    var validResolvedCartfile: String!
    var invalidResolvedCartfile: String!

    var moyaDependency: Dependency!
    var resultDependency: Dependency!
    var alamofireDependency: Dependency!
    var reactiveSwiftDependency: Dependency!
    var rxSwiftDependency: Dependency!
    var yapDatabaseDependency: Dependency!
    var cocoaLumberjackDependency: Dependency!

    // These tuples represent the desired version of a dependency, paired with its parent dependency;
    // moya_3_1_0 indicates that Moya expects a version compatible with 3.1.0 of *another* dependency
    var moya_3_1_0: (Dependency?, VersionSpecifier)!
    var moya_4_1_0: (Dependency?, VersionSpecifier)!
    var reactiveSwift_3_2_1: (Dependency?, VersionSpecifier)!

    override func setUp() {
        validCartfile = """
        github "Alamofire/Alamofire" ~> 4.0
        github "CocoaLumberjack/CocoaLumberjack" ~> 3.0
        github "Moya/Moya" ~> 10.0
        github "ReactiveCocoa/ReactiveSwift" ~> 2.0
        github "ReactiveX/RxSwift" ~> 4.0
        github "antitypical/Result" ~> 3.0
        github "yapstudios/YapDatabase" ~> 3.0
        """

        validResolvedCartfile = """
        github "Alamofire/Alamofire" "4.6.0"
        github "CocoaLumberjack/CocoaLumberjack" "3.4.1"
        github "Moya/Moya" "10.0.2"
        github "ReactiveCocoa/ReactiveSwift" "2.0.1"
        github "ReactiveX/RxSwift" "4.1.2"
        github "antitypical/Result" "3.2.4"
        github "yapstudios/YapDatabase" "3.0.2"
        """

        invalidResolvedCartfile = """
        github "Alamofire/Alamofire" "5.0.0"
        github "CocoaLumberjack/CocoaLumberjack" "commitish"
        github "Moya/Moya" "10.0.2"
        github "ReactiveCocoa/ReactiveSwift" "2.0.1"
        github "ReactiveX/RxSwift" "4.1.2"
        github "antitypical/Result" "4.0.0"
        github "yapstudios/YapDatabase" "3.0.2"
        """

        moyaDependency = Dependency.gitHub(.dotCom, Repository(owner: "Moya", name: "Moya"))
        resultDependency = Dependency.gitHub(.dotCom, Repository(owner: "antitypical", name: "Result"))
        alamofireDependency = Dependency.gitHub(.dotCom, Repository(owner: "Alamofire", name: "Alamofire"))
        reactiveSwiftDependency = Dependency.gitHub(.dotCom, Repository(owner: "ReactiveCocoa", name: "ReactiveSwift"))
        rxSwiftDependency = Dependency.gitHub(.dotCom, Repository(owner: "ReactiveX", name: "RxSwift"))
        yapDatabaseDependency = Dependency.gitHub(.dotCom, Repository(owner: "yapstudios", name: "YapDatabase"))
        cocoaLumberjackDependency = Dependency.gitHub(.dotCom, Repository(owner: "CocoaLumberjack", name: "CocoaLumberjack"))

        // These tuples represent the desired version of a dependency, paired with its parent dependency;
        // moya_3_1_0 indicates that Moya expects a version compatible with 3.1.0 of *another* dependency
        moya_3_1_0 = (moyaDependency, VersionSpecifier.compatibleWith(SemanticVersion(3, 1, 0)))
        moya_4_1_0 = (moyaDependency, VersionSpecifier.compatibleWith(SemanticVersion(4, 1, 0)))
        reactiveSwift_3_2_1 = (reactiveSwiftDependency, VersionSpecifier.compatibleWith(SemanticVersion(3, 2, 1)))
    }

    func testShouldGroupDependenciesByParentDependency() {
        let resolvedCartfile = ResolvedCartfile.from(string: validResolvedCartfile)
        let project = Project(directoryURL: URL(string: "file:///var/empty/fake")!)

        guard let resolvedCartfileValue = resolvedCartfile.value else {
            fail("Could not get resolved cartfile value")
            return
        }

        let result = project.requirementsByDependency(resolvedCartfile: resolvedCartfileValue, tryCheckoutDirectory: false).single()

        expect(result?.value?.count) == 3

        expect(Set(result?.value?.requirements(from: self.moyaDependency)?.map { $0.0 } ?? [])) ==
            Set([resultDependency, alamofireDependency, reactiveSwiftDependency, rxSwiftDependency])

        expect(Set(result?.value?.requirements(from: self.reactiveSwiftDependency)?.map { $0.0 } ?? [])) == Set([resultDependency])

        expect(Set(result?.value?.requirements(from: self.yapDatabaseDependency)?.map { $0.0 } ?? [])) == Set([cocoaLumberjackDependency])
    }

    func testShouldCorrectlyInvertARequirementsDictionary() {
        let a = Dependency.gitHub(.dotCom, Repository(owner: "a", name: "a"))
        let b = Dependency.gitHub(.dotCom, Repository(owner: "b", name: "b"))
        let c = Dependency.gitHub(.dotCom, Repository(owner: "c", name: "c"))
        let d = Dependency.gitHub(.dotCom, Repository(owner: "d", name: "d"))
        let e = Dependency.gitHub(.dotCom, Repository(owner: "e", name: "e"))

        let v1 = VersionSpecifier.compatibleWith(SemanticVersion(1, 0, 0))
        let v2 = VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0))
        let v3 = VersionSpecifier.compatibleWith(SemanticVersion(3, 0, 0))
        let v4 = VersionSpecifier.compatibleWith(SemanticVersion(4, 0, 0))

        let requirements = CompatibilityInfo.Requirements([a: [b: v1, c: v2], d: [c: v3, e: v4]])
        guard let invertedRequirements = CompatibilityInfo.invert(requirements: requirements).value else {
            fail("Could not get invertedRequirements value")
            return
        }
        for expected in [b: [a: v1], c: [a: v2, d: v3], e: [d: v4]] {
            expect(invertedRequirements.contains { $0.0 == expected.0 && $0.1 == expected.1 }) == true
        }
    }

    func testShouldIdentifyIncompatibleDependencies() {
        let commitish = VersionSpecifier.gitReference("55cf7fe10320103f6da1cb3b13aba99244c0943e")
        let v4_0_0 = VersionSpecifier.compatibleWith(SemanticVersion(4, 0, 0))
        let v2_0_0 = VersionSpecifier.compatibleWith(SemanticVersion(2, 0, 0))
        let v4_1_0 = VersionSpecifier.compatibleWith(SemanticVersion(4, 1, 0))
        let v3_1_0 = VersionSpecifier.compatibleWith(SemanticVersion(3, 1, 0))
        let v3_2_1 = VersionSpecifier.compatibleWith(SemanticVersion(3, 2, 1))

        let dependencies: [Dependency: PinnedVersion] = [rxSwiftDependency: PinnedVersion("4.1.2"),
                                                         moyaDependency: PinnedVersion("10.0.2"),
                                                         yapDatabaseDependency: PinnedVersion("3.0.2"),
                                                         alamofireDependency: PinnedVersion("6.0.0"),
                                                         reactiveSwiftDependency: PinnedVersion("2.0.1"),
                                                         cocoaLumberjackDependency: PinnedVersion("55cf7fe10320103f6da1cb3b13aba99244c0943e"),
                                                         resultDependency: PinnedVersion("3.1.7")]

        let requirements: [Dependency: [Dependency: VersionSpecifier]] = [moyaDependency: [rxSwiftDependency: v4_0_0,
                                                                                           reactiveSwiftDependency: v2_0_0,
                                                                                           alamofireDependency: v4_1_0,
                                                                                           resultDependency: v3_1_0],
                                                                          reactiveSwiftDependency: [resultDependency: v3_2_1],
                                                                          yapDatabaseDependency: [cocoaLumberjackDependency: commitish]]

        let infos = CompatibilityInfo.incompatibilities(for: dependencies, requirements: CompatibilityInfo.Requirements(requirements), projectDependencyRetriever: MockProjectDependencyRetriever())
            .value?
            .sorted { $0.dependency.name < $1.dependency.name }

        expect(infos?[0].dependency) == alamofireDependency
        expect(infos?[0].pinnedVersion) == PinnedVersion("6.0.0")

        expect(infos?[0].incompatibleRequirements.contains(where: { $0 == self.moya_4_1_0 })) == true

        expect(infos?[1].dependency) == resultDependency
        expect(infos?[1].pinnedVersion) == PinnedVersion("3.1.7")

        expect(infos?[1].incompatibleRequirements.contains(where: { $0 == self.reactiveSwift_3_2_1 })) == true
    }

    func testShouldIdentifyAvalidResolvedCartfileResolvedAsCompatible() {
        let cartfile = Cartfile.from(string: validCartfile)
        let resolvedCartfile = ResolvedCartfile.from(string: validResolvedCartfile)
        let project = Project(directoryURL: URL(string: "file:///var/empty/fake")!)
        guard let cartfileValue = cartfile.value else {
            fail("Could not get cartfile value")
            return
        }
        guard let resolvedCartfileValue = resolvedCartfile.value else {
            fail("Could not get resolved cartfile value")
            return
        }
        let result = project.validate(cartfile: cartfileValue, resolvedCartfile: resolvedCartfileValue).single()
        expect(result?.value).notTo(beNil())
    }

    func testShouldIdentifyIncompatibilitiesInAnInvalidResolvedCartfileResolved() {
        let cartfile = Cartfile.from(string: validCartfile)
        let resolvedCartfile = ResolvedCartfile.from(string: invalidResolvedCartfile)
        let project = Project(directoryURL: URL(string: "file:///var/empty/fake")!)

        guard let resolvedCartfileValue = resolvedCartfile.value else {
            fail("Could not get resolved cartfile value")
            return
        }

        guard let cartfileValue = cartfile.value else {
            fail("Could not get cartfile value")
            return
        }

        let error = project.validate(cartfile: cartfileValue, resolvedCartfile: resolvedCartfileValue).single()?.error
        let infos = error?.compatibilityInfos.sorted { $0.dependency.name < $1.dependency.name }

        expect(infos?[0].dependency) == alamofireDependency
        expect(infos?[0].pinnedVersion) == PinnedVersion("5.0.0")

        expect(infos?[0].incompatibleRequirements.contains(where: { $0 == self.moya_4_1_0 })) == true

        expect(infos?[1].dependency) == resultDependency
        expect(infos?[1].pinnedVersion) == PinnedVersion("4.0.0")

        expect(infos?[1].incompatibleRequirements.contains(where: { $0 == self.moya_3_1_0 })) == true
        expect(infos?[1].incompatibleRequirements.contains(where: { $0 == self.reactiveSwift_3_2_1 })) == true

        expect(error?.description) ==
        """
        The following incompatibilities were found in Cartfile.resolved:
        * Alamofire 5.0.0 is incompatible with the version constraint specified by Cartfile/Cartfile.private: ~> 4.0.0
        * Alamofire 5.0.0 is incompatible with the version constraint specified by Moya: ~> 4.1.0
        * Result 4.0.0 is incompatible with the version constraint specified by Cartfile/Cartfile.private: ~> 3.0.0
        * Result 4.0.0 is incompatible with the version constraint specified by Moya: ~> 3.1.0
        * Result 4.0.0 is incompatible with the version constraint specified by ReactiveSwift: ~> 3.2.1
        """
    }
}

private class MockProjectDependencyRetriever: DependencyRetrieverProtocol {
    func dependencies(for dependency: Dependency, version: PinnedVersion, tryCheckoutDirectory: Bool) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
        return SignalProducer<(Dependency, VersionSpecifier), CarthageError>.empty
    }

    func resolvedGitReference(_ dependency: Dependency, reference: String) -> SignalProducer<PinnedVersion, CarthageError> {
        return SignalProducer<PinnedVersion, CarthageError>(value: PinnedVersion("26e25edd24ff9ce85fb32bc0f5ab49d29a8c86df"))
    }

    func versions(for dependency: Dependency) -> SignalProducer<PinnedVersion, CarthageError> {
        return SignalProducer<PinnedVersion, CarthageError>.empty
    }
}
