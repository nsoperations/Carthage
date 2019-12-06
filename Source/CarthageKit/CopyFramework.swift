import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD

/**
 Implementation of copyframework for the `copyframeworks` carthage command
 */
public final class CopyFramework {

    // MARK: - Public

    public static func copyFramework(frameworkURL: URL, frameworksFolder: URL, symbolsFolder: URL, validArchitectures: [String], codeSigningIdentity: String?, shouldStripDebugSymbols: Bool, shouldCopyBCSymbolMap: Bool, lockTimeout: Int? = nil, waitHandler: ((URL) -> Void)? = nil) -> SignalProducer<FrameworkEvent, CarthageError> {
        let frameworkName = frameworkURL.lastPathComponent

        let source = Result(
            frameworkURL,
            failWith: CarthageError.invalidArgument(
                description: "Could not find framework \"\(frameworkName)\" at path \(frameworkURL.path). "
                    + "Ensure that the given path is appropriately entered and that your \"Input Files\" and \"Input File Lists\" have been entered correctly."
            )
        )
        var lock: Lock?
        var tempDirectoryURL: URL?
        return URLLock.lockReactive(url: frameworkURL, timeout: lockTimeout, onWait: { urlLock in waitHandler?(urlLock.url) })
            .flatMap(.merge) { urlLock -> SignalProducer<URL, CarthageError> in
                lock = urlLock
                // Create temp directory
                return FileManager.default.reactive.createTemporaryDirectory()
            }
            .flatMap(.merge) { tempURL -> SignalProducer<FrameworkEvent, CarthageError> in
                tempDirectoryURL = tempURL
                return SignalProducer.combineLatest(SignalProducer(result: source), SignalProducer(value: validArchitectures))
                    .flatMap(.merge) { source, validArchitectures -> SignalProducer<FrameworkEvent, CarthageError> in
                        return shouldIgnoreFramework(source, validArchitectures: validArchitectures)
                            .combineLatest(with: shouldSkipFramework(source, frameworksFolder: frameworksFolder))
                            .flatMap(.concat) { shouldIgnore, shouldSkip -> SignalProducer<FrameworkEvent, CarthageError> in
                                if shouldIgnore {
                                    return SignalProducer<FrameworkEvent, CarthageError>(value: FrameworkEvent.ignored(frameworkName))
                                } else if shouldSkip {
                                    return SignalProducer<FrameworkEvent, CarthageError>(value: FrameworkEvent.skipped(frameworkName))
                                } else {
                                    let copyFrameworks = copyFramework(source, frameworksFolder: frameworksFolder, validArchitectures: validArchitectures, codeSigningIdentity: codeSigningIdentity, shouldStripDebugSymbols: shouldStripDebugSymbols, tempFolder: tempURL)
                                    let copyBCSymbols = shouldCopyBCSymbolMap ? copyBCSymbolMapsForFramework(source, symbolsFolder: symbolsFolder, tempFolder: tempURL) : SignalProducer<URL, CarthageError>.empty
                                    let copydSYMs = copyDebugSymbolsForFramework(source, symbolsFolder: symbolsFolder, validArchitectures: validArchitectures, tempFolder: tempURL)
                                    return SignalProducer.combineLatest(copyFrameworks, copyBCSymbols, copydSYMs)
                                        .then(SignalProducer<FrameworkEvent, CarthageError>(value: FrameworkEvent.copied(frameworkName)))
                                }
                        }
                }
            }
            .on(terminated: {
                lock?.unlock()
                tempDirectoryURL?.removeIgnoringErrors()
            })
    }

    // MARK: - Private

    private static func shouldIgnoreFramework(_ framework: URL, validArchitectures: [String]) -> SignalProducer<Bool, CarthageError> {
        return Frameworks.architecturesInPackage(framework)
            .collect()
            .map { architectures in
                // Return all the architectures, present in the framework, that are valid.
                validArchitectures.filter(architectures.contains)
            }
            .map { remainingArchitectures in
                // If removing the useless architectures results in an empty fat file,
                // wat means that the framework does not have a binary for the given architecture, ignore the framework.
                remainingArchitectures.isEmpty
        }
    }

    private static func shouldSkipFramework(_ framework: URL, frameworksFolder: URL) -> SignalProducer<Bool, CarthageError> {
        return SignalProducer<Bool, CarthageError> { () -> Bool in
            let target = frameworksFolder.appendingPathComponent(framework.lastPathComponent)

            guard let targetModificationDate = target.modificationDate,
                let sourceModificationDate = framework.modificationDate else {
                    return false
            }

            return targetModificationDate >= sourceModificationDate
        }
    }

    private static func copyBCSymbolMapsForFramework(_ frameworkURL: URL, symbolsFolder: URL, tempFolder: URL) -> SignalProducer<URL, CarthageError> {
        // This should be called only when `buildActionIsArchiveOrInstall()` is true.
        return SignalProducer(value: symbolsFolder)
            .flatMap(.merge) { destinationURL in
                return Frameworks.BCSymbolMapsForFramework(frameworkURL)
                    .copyFileURLsIntoDirectory(tempFolder)
                    .moveFileURLsIntoDirectory(destinationURL)
        }
    }

    private static func copyDebugSymbolsForFramework(_ frameworkURL: URL, symbolsFolder: URL, validArchitectures: [String], tempFolder: URL) -> SignalProducer<(), CarthageError> {
        return SignalProducer(value: symbolsFolder)
            .flatMap(.merge) { destinationURL in
                return SignalProducer(value: frameworkURL)
                    .map { $0.appendingPathExtension("dSYM") }
                    .copyFileURLsIntoDirectory(tempFolder)
                    .flatMap(.merge) { dSYMURL -> SignalProducer<URL, CarthageError> in
                        return Xcode.stripBinary(dSYMURL, keepingArchitectures: validArchitectures)
                            .then(SignalProducer<URL, CarthageError>(value: dSYMURL))
                    }
                    .moveFileURLsIntoDirectory(destinationURL)
                    .then(SignalProducer<(), CarthageError>.empty)
        }
    }

    private static func copyFramework(_ source: URL, frameworksFolder: URL, validArchitectures: [String], codeSigningIdentity: String?, shouldStripDebugSymbols: Bool, tempFolder: URL) -> SignalProducer<(), CarthageError> {

        return SignalProducer(value: source)
            .copyFileURLsIntoDirectory(tempFolder)
            .flatMap(.merge) { url -> SignalProducer<URL, CarthageError> in
                return Xcode.stripFramework(
                    url,
                    keepingArchitectures: validArchitectures,
                    strippingDebugSymbols: shouldStripDebugSymbols,
                    codesigningIdentity: codeSigningIdentity
                    )
                    .then(SignalProducer(value: url))
            }
            .moveFileURLsIntoDirectory(frameworksFolder)
            .then(SignalProducer<(), CarthageError>.empty)
    }
}
