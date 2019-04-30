import Foundation
import XCTest
import ReactiveTask
@testable import CarthageKit

class TaskTests: XCTestCase {


    func testParseLaunchCommand() {

        let command = """
                "/bin/some command.sh" --server "http://someurl.com" --file '/tmp/${FILE}' --title Some\\ Title --name "\\"name\\"" foo bar
                """

        let task = Task(launchCommand: command)

        XCTAssertEqual("/bin/some command.sh", task.launchPath)

        let expectedArguments = [
            "--server", "http://someurl.com", "--file", "/tmp/${FILE}", "--title", "Some Title", "--name", "\"name\"", "foo", "bar"
        ]

        XCTAssertEqual(expectedArguments, task.arguments)
    }

}
