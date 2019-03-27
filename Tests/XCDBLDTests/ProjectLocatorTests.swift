import XCDBLD
import Foundation
import Nimble
import XCTest

class ProjectLocatorTests: XCTestCase {
    func testShouldPutWorkspacesBeforeProjects() {
        let workspace = ProjectLocator.workspace(URL(fileURLWithPath: "/Z.xcworkspace"))
        let project = ProjectLocator.projectFile(URL(fileURLWithPath: "/A.xcodeproj"))
        expect(workspace < project) == true
    }

    func testShouldFallBackToLexicographicalSorting() {
        let workspaceA = ProjectLocator.workspace(URL(fileURLWithPath: "/A.xcworkspace"))
        let workspaceB = ProjectLocator.workspace(URL(fileURLWithPath: "/B.xcworkspace"))
        expect(workspaceA < workspaceB) == true

        let projectA = ProjectLocator.projectFile(URL(fileURLWithPath: "/A.xcodeproj"))
        let projectB = ProjectLocator.projectFile(URL(fileURLWithPath: "/B.xcodeproj"))
        expect(projectA < projectB) == true
    }

    func testShouldPutTopLevelDirectoriesFirst() {
        let top = ProjectLocator.projectFile(URL(fileURLWithPath: "/Z.xcodeproj"))
        let bottom = ProjectLocator.workspace(URL(fileURLWithPath: "/A/A.xcodeproj"))
        expect(top < bottom) == true
    }
}
