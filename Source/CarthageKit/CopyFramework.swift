import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD

/**
 Implementation of copyframework for the `copyframeworks` carthage command
 */
public final class CopyFramework {

    private static let copyFrameworksTemplate = "carthage-copyframeworks.XXXXXX"

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
        let target = frameworksFolder.appendingPathComponent(frameworkName, isDirectory: true)
        var lock: Lock?
        var tempDirectoryURL: URL?
        return URLLock.lockReactive(url: frameworkURL, timeout: lockTimeout, onWait: { urlLock in waitHandler?(urlLock.url) })
            .flatMap(.merge) { urlLock -> SignalProducer<URL, CarthageError> in
                lock = urlLock
                // Create temp directory
                return FileManager.default.reactive.createTemporaryDirectoryWithTemplate(copyFrameworksTemplate)
            }
            .flatMap(.merge) { tempURL -> SignalProducer<FrameworkEvent, CarthageError> in
                tempDirectoryURL = tempURL
                return SignalProducer.combineLatest(SignalProducer(result: source), SignalProducer(value: target), SignalProducer(value: validArchitectures))
                    .flatMap(.merge) { source, target, validArchitectures -> SignalProducer<FrameworkEvent, CarthageError> in
                        return shouldIgnoreFramework(source, validArchitectures: validArchitectures)
                            .flatMap(.concat) { shouldIgnore -> SignalProducer<FrameworkEvent, CarthageError> in
                                if shouldIgnore {
                                    return SignalProducer<FrameworkEvent, CarthageError>(value: FrameworkEvent.ignored(frameworkName))
                                } else {
                                    let copyFrameworks = copyFramework(source, target: target, validArchitectures: validArchitectures, codeSigningIdentity: codeSigningIdentity, shouldStripDebugSymbols: shouldStripDebugSymbols, tempFolder: tempURL)
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
                            .map { dSYMURL }
                    }
                    .moveFileURLsIntoDirectory(destinationURL)
                    .then(SignalProducer<(), CarthageError>.empty)
        }
    }

    private static func copyFramework(_ source: URL, target: URL, validArchitectures: [String], codeSigningIdentity: String?, shouldStripDebugSymbols: Bool, tempFolder: URL) -> SignalProducer<(), CarthageError> {
        return SignalProducer.combineLatest(Files.copyFile(from: source, to: tempFolder), SignalProducer(value: codeSigningIdentity))
            .flatMap(.merge) { url, codesigningIdentity -> SignalProducer<URL, CarthageError> in
                return Xcode.stripFramework(
                    url,
                    keepingArchitectures: validArchitectures,
                    strippingDebugSymbols: shouldStripDebugSymbols,
                    codesigningIdentity: codesigningIdentity
                ).map { url }
            }
            .moveFileURLsIntoDirectory(target)
            .then(SignalProducer<(), CarthageError>.empty)
    }
}

extension URL {
    fileprivate func removeIgnoringErrors() {
        _ = try? FileManager.default.removeItem(at: self)
    }
}
