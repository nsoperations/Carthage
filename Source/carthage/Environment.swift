import CarthageKit
import Foundation
import Result

final class Environment {

    static func getVariable(_ variable: String, defaultValue: @autoclosure () -> String) -> String {
        let environment = ProcessInfo.processInfo.environment
        return environment[variable] ?? defaultValue()
    }

    static func getVariable(_ variable: String) -> Result<String, CarthageError> {
        let environment = ProcessInfo.processInfo.environment

        if let value = environment[variable] {
            return .success(value)
        } else {
            return .failure(CarthageError.missingEnvironmentVariable(variable: variable))
        }
    }

}

/// Information about the possible parent terminal.
struct Terminal {
    /// Terminal type retrieved from `TERM` environment variable.
    static var terminalType: String? {
        return Environment.getVariable("TERM").value
    }

    /// Whether terminal type is `dumb`.
    static var isDumb: Bool {
        return terminalType?.caseInsensitiveCompare("dumb") == .orderedSame
    }

    /// Whether STDOUT is a TTY.
    static var isTTY: Bool {
        return isatty(STDOUT_FILENO) != 0
    }
}
