//
//  CopyFramework.swift
//  CarthageKit
//
//  Created by Werner Altewischer on 16/04/2019.
//

import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD

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
        let target = frameworksFolder.appendingPathComponent(frameworkName, isDirectory: true)
        var lock: Lock?
        return URLLock.lockReactive(url: frameworkURL, timeout: lockTimeout, onWait: { urlLock in waitHandler?(urlLock.url) })
            .flatMap(.merge) { urlLock -> SignalProducer<FrameworkEvent, CarthageError> in
                lock = urlLock
                return SignalProducer.combineLatest(SignalProducer(result: source), SignalProducer(value: target), SignalProducer(value: validArchitectures))
                    .flatMap(.merge) { source, target, validArchitectures -> SignalProducer<FrameworkEvent, CarthageError> in
                        return shouldIgnoreFramework(source, validArchitectures: validArchitectures)
                            .flatMap(.concat) { shouldIgnore -> SignalProducer<FrameworkEvent, CarthageError> in
                                if shouldIgnore {
                                    return SignalProducer<FrameworkEvent, CarthageError>(value: FrameworkEvent.ignored(frameworkName))
                                } else {
                                    let copyFrameworks = copyFramework(source, target: target, validArchitectures: validArchitectures, codeSigningIdentity: codeSigningIdentity, shouldStripDebugSymbols: shouldStripDebugSymbols)
                                    let copyBCSymbols = shouldCopyBCSymbolMap ? copyBCSymbolMapsForFramework(source, symbolsFolder: symbolsFolder) : SignalProducer<URL, CarthageError>.empty
                                    let copydSYMs = copyDebugSymbolsForFramework(source, symbolsFolder: symbolsFolder, validArchitectures: validArchitectures)
                                    return SignalProducer.combineLatest(copyFrameworks, copyBCSymbols, copydSYMs)
                                        .then(SignalProducer<FrameworkEvent, CarthageError>(value: FrameworkEvent.copied(frameworkName)))
                                }
                        }
                }
            }
            .on(terminated: { lock?.unlock() })
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

    private static func copyBCSymbolMapsForFramework(_ frameworkURL: URL, symbolsFolder: URL) -> SignalProducer<URL, CarthageError> {
        // This should be called only when `buildActionIsArchiveOrInstall()` is true.
        return SignalProducer(value: symbolsFolder)
            .flatMap(.merge) { destinationURL in
                return Frameworks.BCSymbolMapsForFramework(frameworkURL)
                    .copyFileURLsIntoDirectory(destinationURL)
        }
    }

    private static func copyDebugSymbolsForFramework(_ frameworkURL: URL, symbolsFolder: URL, validArchitectures: [String]) -> SignalProducer<(), CarthageError> {
        return SignalProducer(value: symbolsFolder)
            .flatMap(.merge) { destinationURL in
                return SignalProducer(value: frameworkURL)
                    .map { $0.appendingPathExtension("dSYM") }
                    .copyFileURLsIntoDirectory(destinationURL)
                    .flatMap(.merge) { dSYMURL in
                        return stripDSYM(dSYMURL, keepingArchitectures: validArchitectures)
                }
        }
    }

    private static func copyFramework(_ source: URL, target: URL, validArchitectures: [String], codeSigningIdentity: String?, shouldStripDebugSymbols: Bool) -> SignalProducer<(), CarthageError> {
        return SignalProducer.combineLatest(Files.copyProduct(source, target), SignalProducer(value: codeSigningIdentity))
            .flatMap(.merge) { url, codesigningIdentity -> SignalProducer<(), CarthageError> in
                let strip = Xcode.stripFramework(
                    url,
                    keepingArchitectures: validArchitectures,
                    strippingDebugSymbols: shouldStripDebugSymbols,
                    codesigningIdentity: codesigningIdentity
                )
                return strip
        }
    }

    /// Strips a dSYM from unexpected architectures.
    private static func stripDSYM(_ dSYMURL: URL, keepingArchitectures: [String]) -> SignalProducer<(), CarthageError> {
        return Xcode.stripBinary(dSYMURL, keepingArchitectures: keepingArchitectures)
    }
}
