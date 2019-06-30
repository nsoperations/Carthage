import Foundation
import ReactiveSwift
import ReactiveTask
import Result
import Tentacle

extension SignalProducer where Value == Release, Error == CarthageError {

    /// Synchronously returns the semantic version of the newest release,
    /// if the given producer emits it within a reasonable timeframe.
    ///
    public func getLatestVersion() -> Version? {
        let latestRemoteVersion = self
            .attemptMap { release -> Result<Version, CarthageError> in
                return Version.from(Scanner(string: release.tag)).mapError(CarthageError.init(scannableError:))
            }
            // Add timeout on different queue so that `first()` doesn't block timeout scheduling
            .timeout(after: 0.5, raising: CarthageError.gitHubAPITimeout, on: QueueScheduler(qos: .default))
            .first()
        return latestRemoteVersion?.value
    }
}
