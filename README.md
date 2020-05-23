![](Logo/PNG/header.png)

# Carthage [![GitHub license](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/nsoperations/Carthage/master/LICENSE.md) [![GitHub release](https://img.shields.io/github/release/nsoperations/carthage.svg)](https://github.com/nsoperations/Carthage/releases) [![Reviewed by Hound](https://img.shields.io/badge/Reviewed_by-Hound-8E64B0.svg)](https://houndci.com)

Carthage is intended to be the simplest way to add frameworks to your Cocoa application.

Carthage builds your dependencies and provides you with binary frameworks, but you retain full control over your project structure and setup. Carthage does not automatically modify your project files or your build settings.

This is a fork on the official [Carthage](https://github.com/Carthage/Carthage) which fixes a lot of issues, most importantly:

- Fixes resolver issues: replaces both the original and new resolver with a completely rewritten resolver which passes all (performance) tests. Also added a lot more tests based on JSON fixtures for problematic dependency trees. The flag --new-resolver does not exist anymore.
- Adds the carthage `diagnose` command for creating new test fixtures for problematic dependency trees.
- Fixes concurrency issues: all file system actions upon potentially shared resource (checkout cache, derived data folder, binaries cache, etc) are now protected with locks based on the system utility shlock. This ensures that CI systems can run multiple Carthage jobs in parallel. An option `--lock-timeout` has been added to relevant commands to specify a custom time-out in seconds for acquiring locks (default is no time-out).
- Fixes the DWARFs symbol problem for pre-built cached binaries by automatically creating mapping plists in the dSYM bundles for the relevant sources. This allows for debugging Carthage dependencies which were not built on the developer machine.
- Adds a plugable caching mechanism, enabled by the option `--cache-command` for all build-related commands. A custom shell script or executable can be specified to retrieve cached binaries from arbitrary back-ends. The CARTHAGE_CACHE_COMMAND environment variable is used as a default for this command. If not defined, a fall back to the original GitHub API based caching will take place.
- Ensures the caching mechanism tasks Swift toolchain version and build configuration (Debug/Release) into account. The binaries cache folders (under ~/Library/Caches/org.carthage.CarthageKit/binaries) now have the following directory structure: $SWIFT_VERSION/$DEPENDENCY_NAME/$DEPENDENCY_VERSION/$BUILD_CONFIGURATION.
- Adds support for a Cartfile.schemes file, which can be added to a project to limit the schemes considered by Carthage for building. Just add the scheme names to consider to this file (one per line).
- Adds support for automatic discovery of frameworks to copy using the `--auto` flag for the `copy-frameworks` command.
- Adds support for local storage of binary builds in the carthage binaries cache when the build option `--use-binaries` is enabled (which is the default).
- Adds support for automatic rebuilding of cached dependencies when local changes have been made using the build option `--track-local-changes`

See [this video](https://youtu.be/21nbRGpy3xM) for an overview and some demos.

To install:

`brew tap nsoperations/formulas && brew install nsoperations/formulas/carthage`

See [Installing Carthage](#installing-carthage)

## Contents

- [Change Log](#change-log)
- [Quick Start](#quick-start)
- [Installing Carthage](#installing-carthage)
- [Adding frameworks to an application](#adding-frameworks-to-an-application)
	- [Getting started](#getting-started)
		- [If you're building for macOS](#if-youre-building-for-macos)
		- [If you're building for iOS, tvOS, or watchOS](#if-youre-building-for-ios-tvos-or-watchos)
		- [For both platforms](#for-both-platforms)
		- [(Optionally) Add build phase to warn about outdated dependencies](#optionally-add-build-phase-to-warn-about-outdated-dependencies)
		- [Swift binary framework download compatibility](#swift-binary-framework-download-compatibility)
	- [Running a project that uses Carthage](#running-a-project-that-uses-carthage)
	- [Adding frameworks to unit tests or a framework](#adding-frameworks-to-unit-tests-or-a-framework)
	- [Upgrading frameworks](#upgrading-frameworks)
	- [Diagnosing resolver problems](#diagnosing-resolver-problems)
	- [Nested dependencies](#nested-dependencies)
	- [Using submodules for dependencies](#using-submodules-for-dependencies)
	- [Automatically rebuilding dependencies](#automatically-rebuilding-dependencies)
	- [Caching builds](#caching-builds)
	- [Bash/Zsh/Fish completion](#bashzshfish-completion)
- [Supporting Carthage for your framework](#supporting-carthage-for-your-framework)
	- [Share your Xcode schemes](#share-your-xcode-schemes)
	- [Filter discoverable schemes](#filter-discoverable-schemes)
	- [Resolve build failures](#resolve-build-failures)
	- [Tag stable releases](#tag-stable-releases)
	- [Archive prebuilt frameworks into one zip file](#archive-prebuilt-frameworks-into-one-zip-file)
		- [Use travis-ci to upload your tagged prebuilt frameworks](#use-travis-ci-to-upload-your-tagged-prebuilt-frameworks)
	- [Build static frameworks to speed up your app’s launch times](#build-static-frameworks-to-speed-up-your-apps-launch-times)
	- [Declare your compatibility](#declare-your-compatibility)
- [CarthageKit](#carthagekit)
- [Differences between Carthage and CocoaPods](#differences-between-carthage-and-cocoapods)
- [License](#license)

## Change Log

### 0.46.1+nsoperations

- Fixed bug where binary dependency in tar (gz) format could not be installed
- Fixed deadlock in case a binary dependency referenced another binary dependency

### 0.46.0+nsoperations

- Added support for frameworks built with module stability in combination binary caching

### 0.45.1+nsoperations

- Fixed bug with `--dependencies-hash` where the hash would not be stored in the version file if the flag was not supplied.

### 0.45.0+nsoperations

- Added writing of a file called Carthage/.resolved.md5 which is used to cross-reference if the current Carthage/Checkouts are up-to-date with the Cartfile.resolved. If not `build` will fail with an error.
- Added build flag `--dependencies-hash` which if supplied enforces the cross-reference of the hash of transitive dependencies for binary caches. This is to avoid issues with a mismatch of transitive dependencies at build time vs. run time for non-module stable builds. There is also a cross-reference of symbol tables which is always performed (irrespective of this flag) as fallback. Specify this flag to be absolutely sure that the cached build corresponds to the exact same set of pinned dependency versions. In Debug mode on developer machines this flag should most of the time not be supplied for speed purposes (alows for more cache hits), but on the CI it does make sense. 0.44.* versions implicitly enabled this mode always.

### 0.44.2+nsoperations

- Fixed IRGen error during debugging for locally made builds because derived data folder was split between sdks

### 0.44.1+nsoperations

- Fixed deadlock issue which occurred sometimes during build

### 0.44.0+nsoperations

- Ensured binary caching takes the combination of concrete versioned dependencies at build time into account, because of issues with module instability in none xcframeworks.
- Optimized the performance by greatly improving the parallelization of tasks.
- Added command `dependencies-hash` to show the hash of the Cartfile.resolved which is cross-referenced for caching.
- Improved binary symbol cross-reference to be sure no missing symbols exist when installing pre-built binaries.

### 0.43.1+nsoperations

- Ensured only binaries built with the option `--build-for-distribution` are stored in the local binary cache.
- Ensured symbol map is updated before checking the cached builds in the Carthage/Build folder as well as after downloading any binaries to be completely sure no symbol linking issues will occur.

### 0.43.0+nsoperations

- Added the flag `--valid-simulator-identifiers` to limit the set of simulator identifiers to be considered for building when discovering the simulator destination to build for.

### 0.42.0+nsoperations

- Added build option `--build-for-distribution` to enforce the flag BUILD_LIBRARY_FOR_DISTRIBUTION=YES to enable the Swift module stability feature.

### 0.41.6+nsoperations

- Removed build flag BUILD_LIBRARY_FOR_DISTRIBUTION=YES which caused problems

### 0.41.5+nsoperations

- Ensured recompilation happens for cached binaries if the linked symbols do not match. See: https://bugs.swift.org/browse/SR-11906

### 0.41.4+nsoperations

- Fixed bug with the `copy-frameworks --auto` function where watch frameworks would not be discovered
- Ensured `carthage build` will always perform a clean build to avoid issues with stale data in the derived data folder

### 0.41.3+nsoperations

- Improved performance of `update` by prefetching all required remote git dependencies in parallel
- Improved performance of `bootstrap` by reverting an earlier change which resulted in always fetching all dependencies.
- Fixed issue when `carthage build` with binaries enabled could fail if no frameworks had to be built.

### 0.41.2+nsoperations

- Fixed bug where removing transitive dependencies (remove dependencies from Cartfile) could lead to an error when running `carthage update`

### 0.41.1+nsoperations

- Fixed bug where concurrent git fetches on `bootstrap` could corrupt the local git cache
- Fixes issue where an empty Cartfile.project was not properly recognized
- Ensured that after a failed fetch a clean git clone is tried to recover from any locally corrupted state
- Improved log output
- Added a warning which is logged if no Cartfile.project is present for a project to be built with `carthage build`
- Renamed the command `generate-projectfile` to `generate-project-file`
- Ensured `generate-project-file` writes to Cartfile.project instead of echoing to stdout.
- Removed the --xcode-warnings flag from the `outdated` command, output now always is compatible with Xcode.
- Ensured that warnings and errors show up in the Xcode log if they occur

### 0.41.0+nsoperations

- Added support for Cartfile.project, a yml-file describing the Xcode project/workspace, schemes and sdks to build which speeds up the pre-build project introspection very significantly
- Added `generate-projectfile` command to auto-generate a project file from the current state of the project tree using the old auto-discovery method.
- Improved build performance by building same level dependencies in parallel
- Improved build performance by building multiple sdks for same scheme in parallel
- Ensure compilation mode wholemodule is always use to avoid waste of CPU resources
- Ensured parallel tasks is dynamically determined based on the number of available CPU cores
- Added caching for a lot of read-only Swift, Git and Xcodebuild commands, thereby improving performance a lot
- Fixed bug where fetch for remote dependencies would not always take place on update/bootstrap.
- Removed -destinationTimeout override for xcodebuild, will now just use the default.

### 0.40.2+nsoperations

- Ignored all .xcscheme files from source hash calculation because of Xcode touching those files when viewing the scheme list
- Improved performance by caching some commonly used read-only shell commands

### 0.40.1+nsoperations

- Fixed bug where checkout (or bootstrap/update) would not properly clean left over files from a previous checkout leading to unexpected results
- Increased simulator discovery timeout from 3 to 10 seconds to avoid issues on some systems.
- Fixed bug where carthage validate would fail if the checkouts folder was not up to date
- Improved message which is printed when a dependency cycle is present: now print the actual cycle
- Fixed bug where symlinks would not be created for all transitive dependencies of a dependency in both the build folder and the checkouts folder
- Ensured schemes, IDEWorkspaceChecks.plist and WorkspaceSettings.xcsettings are not included when calculating a source hash to avoid invalidation if auto-creation of schemes is active. The exception is if schemes are listed in Cartfile.schemes.

### 0.40.0+nsoperations

- Added option `--commitish` and `--project-name` to the build command which can override the auto-detected git ref and project name to use when `--no-skip-current` is present for the project to build.

### 0.39.3+nsoperations

- Fixed minor bug in .gitignore interpretation, specifically regarding leading spaces

### 0.39.2+nsoperations

- Fixed calculation of sourceHash for the purpose of `--track-local-changes` so files which match patterns in .gitignore are not included. This ensures that temporary files written by the build process won't cause the sourceHash to change.

### 0.39.1+nsoperations

- Ensured the swift language version is also taken into account when checking version compatibility between binary frameworks and the current swift version

### 0.39.0+nsoperations

- Added support .bundle resources inside binary dependencies. The binary zip is scanned for .bundle resources which are installed also as part of the binary installation process.
- Added support .netrc for authenticated http resources for binary dependencies. Works for the `update`, `bootstrap`, `build`, `diagnose` and `outdated` commands.
- Fixed bug where carthage would go into an infinite loop while trying to resolve the original build path in the DebugSymbolMapper
- Added the `swift-version` command to show the current Swift version as in use and parsed by carthage (to cross match against dependency's Swift versions)

### 0.38.1+nsoperations
- Fixed bug where `validate` failed for non semantic versions (git references).

### 0.38.0+nsoperations
- Ensured the `validate` command also takes Cartfile/Cartfile.private into account in addition to Cartfile.resolved. This will ensure that incompatibilities between the Cartfile and Cartfile.resolved will cause the validation to fail.

### 0.37.1+nsoperations

- Fixed bug in matching build configuration for binary dependencies from JSON file
- Fixed bug in parsing of command line arguments for the `update` command
- Fixed bug in debug symbol mapping resulting in the wrong binary/dsym path being stored.
- Made source hash calculation more reliable by first sorting the files to calculate the hash on

### 0.37.0+nsoperations

- Added build option `--track-local-changes` to invalidate caches (in effect with `--cache-builds` and/or `--use-binaries`) when local changes were made to the source code of dependencies. This is handy for debugging the source code of dependencies.

### 0.36.3+nsoperations

- Fixed bug where local binary caching would not work if CARTHAGE_CACHE_COMMAND environment variable was not present and the dependency was not a GitHub dependency.
- Fixed bug where non-existent dependencies supplied to carthage build would result in all dependencies being built.

### 0.36.2+nsoperations

- Fixed bug where build would fail for frameworks where the framework name differs from the dependency name.

### 0.36.1+nsoperations

- Fixed bug in determining the swift framework version if a non-default generated objective C header was configured for that framework.
- Fixed documentation for the `--no-use-binaries` build option.
- Fixed issues with the resolver regarding the resolution of git references (branch dependencies)
- Enabled verbose resolver logging if `--verbose` option is active during `update`
- Fixed bug where binary-only frameworks would cause `bootstrap` command to fail because the debug symbol mapper would fail on the sources not being there.

### 0.36.0+nsoperations

- Added support for the `--auto` flag for the `copy-frameworks` command to automate the discovery of frameworks to copy.
- Added local storage of built binaries in the local shared binary cache so subsequent builds in different checkout directories can benefit from binary caching. The symbols will be automatically mapped to represent the correct directories.

### 0.35.1+nsoperations

- Ensured project compiles with Xcode 10.2/Swift 5 toolchain

### 0.35.0+nsoperations

- Added support for a Cartfile.schemes file to be able to limit the schemes considered by Carthage for building. Add the name of the scheme which carthage should consider, one per line.
- Added support for mapping of dSYM build paths to local source paths for debugging with externally built binaries.
- Ensured the internal binaries cache now honors the swift toolchain version and build configuration (Debug/Release).
- Implemented a plugable caching mechanism, supported for all build-related actions with the `--cache-command` option or the CARTHAGE_CACHE_COMMAND environment variable. See the help output (e.g. `carthage help build`) for more details.
- Ensure all build and archive operations are now also protected with locks to allow concurrent operations on the same Carthage/Checkouts dir or Carthage/Build dir and most importantly on any shared derived data directories.

### 0.34.0+nsoperations

- Ensured operations on the shared caches (binaries/git) are protected with file system locks to allow concurrent running of carthage update or carthage bootstrap jobs.

### 0.33.0+nsoperations

Up-to-date with version 0.33.0 of the original Carthage. Additionally it contains the following functionality:

- Got rid of the original carthage resolver and the new resolver (flag --new-resolver) in favor of a completely re-written resolver which passes all (performance) test cases (a whole lot of test cases were added, based on json fixtures for problematic dependency trees)
- Added the carthage diagnose command to be able to create offline test fixtures for problematic dependency trees.
- Refactored some project internals, most prominently now use tabs instead of spaces for all indentations (because that's the Xcode default and works with swiftlint autoformat). Also removed quick as test implementation because it caused flaky test failures and prohibited running individual tests from the Xcode UI. Made sure that `make xcodeproj` will generate a script stage for copying the test resources (requires the `xcodeproj` gem to be installed)

## Quick Start

1. Get Carthage by running `brew tap nsoperations/formulas && brew install nsoperations/formulas/carthage` or choose [another installation method](#installing-carthage)
1. Create a [Cartfile][] in the same directory where your `.xcodeproj` or `.xcworkspace` is
1. List the desired dependencies in the [Cartfile][], for example:

	```
	github "Alamofire/Alamofire" ~> 4.7.2
	```

1. Run `carthage update`
1. A `Cartfile.resolved` file and a `Carthage` directory will appear in the same directory where your `.xcodeproj` or `.xcworkspace` is
1. Drag the built `.framework` binaries from `Carthage/Build/<platform>` into your application’s Xcode project.
1. If you are using Carthage for an application, follow the remaining steps, otherwise stop here.
1. On your application targets’ _Build Phases_ settings tab, click the _+_ icon and choose _New Run Script Phase_. Create a Run Script in which you specify your shell (ex: `/bin/sh`), add the following contents to the script area below the shell:

    ```sh
    /usr/local/bin/carthage copy-frameworks --auto
    ```

From that point all of the Carthage's frameworks that are linked againts your target will be copied automatically.

In case you need to specify path to your framework manually for whatever reason, do:

- Add the paths to the frameworks you want to use under “Input Files". For example:

    ```
    $(SRCROOT)/Carthage/Build/iOS/Alamofire.framework
    ```

- Add the paths to the copied frameworks to the “Output Files”. For example:

    ```
    $(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/Alamofire.framework
    ```

For an in depth guide, read on from [Adding frameworks to an application](#adding-frameworks-to-an-application)

## Installing Carthage

There are multiple options for installing Carthage:

* **Installer:** Download and run the `Carthage.pkg` file for the latest [release](https://github.com/nsoperations/Carthage/releases), then follow the on-screen instructions. If you are installing the pkg via CLI, you might need to run `sudo chown -R $(whoami) /usr/local` first.

* **Homebrew:** You can use [Homebrew](http://brew.sh) and install the `carthage` tool on your system. Since this is a fork you need to first tap the forked formula by `brew tap nsoperations/formulas`. Then run simply run `brew update` and `brew install -s nsoperations/formulas/carthage`. (note: if you previously installed the binary version of Carthage, you should delete `/Library/Frameworks/CarthageKit.framework`. If you installed the official carthage via brew, first remove it via `brew uninstall carthage`).

* **From source:** If you’d like to run the latest development version (which may be highly unstable or incompatible), simply clone the `master` branch of the repository, then run `make install` or `make prefix_install PREFIX="<INSTALL_DIR>"`. Requires Xcode 9.4 (Swift 4.1).

## Adding frameworks to an application

Once you have Carthage [installed](#installing-carthage), you can begin adding frameworks to your project. Note that Carthage only supports dynamic frameworks, which are **only available on iOS 8 or later** (or any version of OS X).

### Getting started

##### If you're building for macOS

1. Create a [Cartfile][] that lists the frameworks you’d like to use in your project.
1. Run `carthage update --platform macOS`. This will fetch dependencies into a [Carthage/Checkouts][] folder and build each one or download a pre-compiled framework.
1. On your application targets’ _General_ settings tab, in the _Embedded Binaries_ section, drag and drop each framework you want to use from the [Carthage/Build][] folder on disk.

Additionally, you'll need to copy debug symbols for debugging and crash reporting on OS X.

1. On your application target’s _Build Phases_ settings tab, click the _+_ icon and choose _New Copy Files Phase_.
1. Click the _Destination_ drop-down menu and select _Products Directory_.
1. For each framework you’re using, drag and drop its corresponding dSYM file.

##### If you're building for iOS, tvOS, or watchOS

1. Create a [Cartfile][] that lists the frameworks you’d like to use in your project.
1. Run `carthage update`. This will fetch dependencies into a [Carthage/Checkouts][] folder, then build each one or download a pre-compiled framework.
1. On your application targets’ _General_ settings tab, in the “Linked Frameworks and Libraries” section, drag and drop each framework you want to use from the [Carthage/Build][] folder on disk.
1. On your application targets’ _Build Phases_ settings tab, click the _+_ icon and choose _New Run Script Phase_. Create a Run Script in which you specify your shell (ex: `/bin/sh`), add the following contents to the script area below the shell:

###### Automatic

    ```sh
    /usr/local/bin/carthage copy-frameworks --auto
    ```

From this point Carthage will infer and copy all Carthage's frameworks that are linked against target. It also capable to copy transitive frameworks. For example, you have linked to your app `SocialSDK-Swift` that links internally `SocialSDK-ObjC` which in turns uses utilitary dependency `SocialTools`. In this case you don't need transient dependencies it should be enough to link against your target only `SocialSDK-Swift`. Transient dependencies will be resolved and copied automatically to your app.

Optionally you can add `--verbose` flag to see which frameworks are being copied by Carthage.

###### Manual

    ```sh
    /usr/local/bin/carthage copy-frameworks
    ```

1. Add the paths to the frameworks you want to use under “Input Files". For example:

    ```
    $(SRCROOT)/Carthage/Build/iOS/Result.framework
    $(SRCROOT)/Carthage/Build/iOS/ReactiveSwift.framework
    $(SRCROOT)/Carthage/Build/iOS/ReactiveCocoa.framework
    ```

1. Add the paths to the copied frameworks to the “Output Files”. For example:

    ```
    $(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/Result.framework
    $(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/ReactiveSwift.framework
    $(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/ReactiveCocoa.framework
    ```

    With output files specified alongside the input files, Xcode only needs to run the script when the input files have changed or the output files are missing. This means dirty builds will be faster when you haven't rebuilt frameworks with Carthage.

This script works around an [App Store submission bug](http://www.openradar.me/radar?id=6409498411401216) triggered by universal binaries and ensures that necessary bitcode-related files and dSYMs are copied when archiving.

With the debug information copied into the built products directory, Xcode will be able to symbolicate the stack trace whenever you stop at a breakpoint. This will also enable you to step through third-party code in the debugger.

When archiving your application for submission to the App Store or TestFlight, Xcode will also copy these files into the dSYMs subdirectory of your application’s `.xcarchive` bundle.

###### Combining Automatic and Manual copying

Note that you can combine both automatic and manual ways to copy frameworks, however manually specified frameworks always take precedence over automatically inferred. Therefore in case you have `SomeFramework.framework` located anywhere as well as `SomeFramework.framework` located at `./Carthage/Build/<platform>/`, Carthage will pick manually specified framework. This is useful when you're working with development frameworks and want to copy your version of the framework instead of default one.
Important to undestand, that Carthage won't resolve transient dependencies for your custom framework unless they either located at `./Carthage/Build/<platform>/` or specified manually in “Input Files".

###### Automatic depencencies copying FRAMEWORK_SEARCH_PATHS

If you're working on a development dependencies and would like to utilize `--auto` flag to automate copying of the build artifacts you also can be interested in using `--use-framework-search-paths` flag. This will instruct Carthage to search for a linked dependcies and copy them using `FRAMEWORK_SEARCH_PATHS` environment variable.

##### For both platforms

Along the way, Carthage will have created some [build artifacts][Artifacts]. The most important of these is the [Cartfile.resolved][] file, which lists the versions that were actually built for each framework. **Make sure to commit your [Cartfile.resolved][]**, because anyone else using the project will need that file to build the same framework versions.

##### (Optionally) Add build phase to warn about outdated dependencies

You can add a Run Script phase to automatically warn you when one of your dependencies is out of date.

1. On your application targets’ `Build Phases` settings tab, click the `+` icon and choose `New Run Script Phase`. Create a Run Script in which you specify your shell (ex: `/bin/sh`), add the following contents to the script area below the shell:

```sh
/usr/local/bin/carthage outdated --xcode-warnings | 2>/dev/null
```

##### Swift binary framework download compatibility

Carthage will check to make sure that downloaded Swift (and mixed Objective-C/Swift) frameworks were built with the same version of Swift that is in use locally. If there is a version mismatch, Carthage will proceed to build the framework from source. If the framework cannot be built from source, Carthage will fail.

Because Carthage uses the output of `xcrun swift --version` to determine the local Swift version, make sure to run Carthage commands with the Swift toolchain that you intend to use. For many use cases, nothing additional is needed. However, for example, if you are building a Swift 2.3 project using Xcode 8.x, one approach to specifying your default `swift` for `carthage bootstrap` is to use the following command:

```
TOOLCHAINS=com.apple.dt.toolchain.Swift_2_3 carthage bootstrap
```

### Running a project that uses Carthage

After you’ve finished the above steps and pushed your changes, other users of the project only need to fetch the repository and run `carthage bootstrap` to get started with the frameworks you’ve added.

### Adding frameworks to unit tests or a framework

Using Carthage for the dependencies of any arbitrary target is fairly similar to [using Carthage for an application](#adding-frameworks-to-an-application). The main difference lies in how the frameworks are actually set up and linked in Xcode.

Because unit test targets are missing the _Linked Frameworks and Libraries_ section in their _General_ settings tab, you must instead drag the [built frameworks][Carthage/Build] to the _Link Binaries With Libraries_ build phase.

In the Test target under the _Build Settings_ tab, add `@loader_path/Frameworks` to the _Runpath Search Paths_ if it isn't already present.

In rare cases, you may want to also copy each dependency into the build product (e.g., to embed dependencies within the outer framework, or make sure dependencies are present in a test bundle). To do this, create a new _Copy Files_ build phase with the _Frameworks_ destination, then add the framework reference there as well. You shouldn't use the `carthage copy-frameworks` command since test bundles don't need frameworks stripped, and running concurrent instances of `copy-frameworks` (with parallel builds turn on) is not supported.

### Upgrading frameworks

If you’ve modified your [Cartfile][], or you want to update to the newest versions of each framework (subject to the requirements you’ve specified), simply run the `carthage update` command again.

If you only want to update one, or specific, dependencies, pass them as a space-separated list to the `update` command. e.g.

```
carthage update Box
```

or

```
carthage update Box Result
```

### Diagnosing resolver problems

If you have problematic dependency trees for which the resolver gives unexpected results or performs very slowly, please run the carthage diagnose command and zip the produced results directory. This can be used to setup an offline test case for this dependency tree. You can anonimize the names of dependencies used via a mapping file. Please see:

```
carthage help diagnose
```

### Nested dependencies

If the framework you want to add to your project has dependencies explicitly listed in a [Cartfile][], Carthage will automatically retrieve them for you. You will then have to **drag them yourself into your project** from the [Carthage/Build] folder.

If the embedded framework in your project has dependencies to other frameworks you must  **link them to application target** (even if application target does not have dependency to that frameworks and never uses them).

### Using submodules for dependencies

By default, Carthage will directly [check out][Carthage/Checkouts] dependencies’ source files into your project folder, leaving you to commit or ignore them as you choose. If you’d like to have dependencies available as Git submodules instead (perhaps so you can commit and push changes within them), you can run `carthage update` or `carthage checkout` with the `--use-submodules` flag.

When run this way, Carthage will write to your repository’s `.gitmodules` and `.git/config` files, and automatically update the submodules when the dependencies’ versions change.

### Automatically rebuilding dependencies

If you want to work on your dependencies during development, and want them to be automatically rebuilt when you build your parent project, you can add a Run Script build phase that invokes Carthage like so:

```sh
/usr/local/bin/carthage build --platform "$PLATFORM_NAME" --project-directory "$SRCROOT"
```

Note that you should be [using submodules](#using-submodules-for-dependencies) before doing this, because plain checkouts [should not be modified][Carthage/Checkouts] directly.

### Caching builds

By default Carthage will rebuild a dependency regardless of whether it's the same resolved version as before. Passing the `--cache-builds` will cause carthage to avoid rebuilding a dependency if it can. See information on [version files][VersionFile] for details on how Carthage performs this caching.

Note: At this time `--cache-builds` is incompatible with `--use-submodules`. Using both will result in working copy and committed changes to your submodule dependency not being correctly rebuilt. See [#1785](https://github.com/Carthage/Carthage/issues/1785) for details.

The option `--use-binaries` (which is true by default, specify `--no-use-binaries` to disable) will try to find binary cached dependencies. This works independently of the `--cache-builds` option.
Binaries will be resolved from the local shared cache or, if not available there, will be downloaded from a remote location.

By default Carthage will use remote binary caching based on releases published in GitHub. However there is a plugable caching mechanism exposed via the `--cache-command` option which can be supplied to all commands which execute carthage build (update, bootstrap, build). Specify a custom executable with this `--cache-command` option to implement caching in a custom way or specify the environment variable CARTHAGE_CACHE_COMMAND to achieve the same.
The executable will receive six environment variables from Carthage: [CARTHAGE_CACHE_DEPENDENCY_NAME, CARTHAGE_CACHE_DEPENDENCY_HASH, CARTHAGE_CACHE_DEPENDENCY_VERSION, CARTHAGE_CACHE_BUILD_CONFIGURATION, CARTHAGE_CACHE_SWIFT_VERSION, CARTHAGE_CACHE_TARGET_FILE_PATH]

The executable should resolve a binary zip file as produced via the carthage archive command (or carthage build --archive) compatible with the specified dependency options (name, hash, version, build config, swift toolchain version) and should move the file to the file path denoted by the CARTHAGE_CACHE_TARGET_FILE_PATH environment variable.

### HTTP authentication for binaries

Specify the `--use-netrc` flag to `build`, `update`, `bootstrap`, `diagnose` or `outdated` commands to enable HTTP authentication based on the locally stored $HOME/.netrc file for binary dependency retrieval.

For OAuth2 bearer token authentication: specify `oauth2` as login and the token as password in the .netrc file.

### Bash/Zsh/Fish completion

Auto completion of Carthage commands and options are available as documented in [Bash/Zsh/Fish Completion][Bash/Zsh/Fish Completion].

## Supporting Carthage for your framework

**Carthage only officially supports dynamic frameworks**. Dynamic frameworks can be used on any version of OS X, but only on **iOS 8 or later**. Additionally, since version 0.30.0 Carhage supports **static** frameworks.

Because Carthage has no centralized package list, and no project specification format, **most frameworks should build automatically**.

The specific requirements of any framework project are listed below.

### Share your Xcode schemes

Carthage will only build Xcode schemes that are shared from your `.xcodeproj`. You can see if all of your intended schemes build successfully by running `carthage build --no-skip-current`, then checking the [Carthage/Build][] folder.

If an important scheme is not built when you run that command, open Xcode and make sure that the [scheme is marked as _Shared_](https://developer.apple.com/library/content/documentation/IDEs/Conceptual/xcode_guide-continuous_integration/ConfigureBots.html#//apple_ref/doc/uid/TP40013292-CH9-SW3), so Carthage can discover it.

### Filter discoverable schemes

To only expose a subset of the shared schemes to Carthage add a Cartfile.schemes to your project listing the scheme names to consider. List one scheme name per line. Schemes not listed in this file will be ignored.

### Resolve build failures

If you encounter build failures in `carthage build --no-skip-current`, try running `xcodebuild -scheme SCHEME -workspace WORKSPACE build` or `xcodebuild -scheme SCHEME -project PROJECT build` (with the actual values) and see if the same failure occurs there. This should hopefully yield enough information to resolve the problem.

If you have multiple versions of the Apple developer tools installed (an Xcode beta, for example), use `xcode-select` to change which version Carthage uses.

If you’re still not able to build your framework with Carthage, please [open an issue](https://github.com/Carthage/Carthage/issues/new) and we’d be happy to help!

### Tag stable releases

Carthage determines which versions of your framework are available by searching through the tags published on the repository, and trying to interpret each tag name as a [semantic version](https://semver.org/). For example, in the tag `v1.2`, the semantic version is 1.2.0.

Tags without any version number, or with any characters following the version number (e.g., `1.2-alpha-1`) are currently unsupported, and will be ignored.

### Archive prebuilt frameworks into one zip file

Carthage can automatically use prebuilt frameworks, instead of building from scratch, if they are attached to a [GitHub Release](https://help.github.com/articles/about-releases/) on your project’s repository or via a binary project definition file.

To offer prebuilt frameworks for a specific tag, the binaries for _all_ supported platforms should be zipped up together into _one_ archive, and that archive should be attached to a published Release corresponding to that tag. The attachment should include `.framework` in its name (e.g., `ReactiveCocoa.framework.zip`), to indicate to Carthage that it contains binaries. The directory structure of the acthive is free form but, __frameworks should only appear once in the archive__ as they will be copied
to `Carthage/Build/<platform>` based on their name (e.g. `ReactiveCocoa.framework`).

You can perform the archiving operation with carthage itself using:

```sh
-carthage build --no-skip-current
-carthage archive YourFrameworkName
```

or alternatively

```sh
carthage build --archive
```

Draft Releases will be automatically ignored, even if they correspond to the desired tag.

#### Use travis-ci to upload your tagged prebuilt frameworks

It is possible to use travis-ci in order to build and upload your tagged releases.

1. [Install travis CLI](https://github.com/travis-ci/travis.rb#installation) with `gem install travis`
1. [Setup](https://docs.travis-ci.com/user/getting-started/) travis-ci for your repository (Steps 1 and 2)
1. Create `.travis.yml` file at the root of your repository based on that template. Set `FRAMEWORK_NAME` to the correct value.

	Replace PROJECT_PLACEHOLDER and SCHEME_PLACEHOLDER

	If you are using a *workspace* instead of a *project* remove the xcode_project line and uncomment the xcode_workspace line.

	The project should be in the format: MyProject.xcodeproj

	The workspace should be in the format: MyWorkspace.xcworkspace

	Feel free to update the `xcode_sdk` value to another SDK, note that testing on iphoneos SDK would require you to upload a code signing identity

	For more informations you can visit [travis docs for objective-c projects](https://docs.travis-ci.com/user/languages/objective-c)

	```YAML
	language: objective-c
	osx_image: xcode7.3
	xcode_project: <PROJECT_PLACEHOLDER>
	# xcode_workspace: <WORKSPACE_PLACEHOLDER>
	xcode_scheme: <SCHEME_PLACEHOLDER>
	xcode_sdk: iphonesimulator9.3
	env:
	  global:
	    - FRAMEWORK_NAME=<THIS_IS_A_PLACEHOLDER_REPLACE_ME>
	before_install:
	  - brew update
	  - brew outdated carthage || brew upgrade carthage
	before_script:
	  # bootstrap the dependencies for the project
	  # you can remove if you don't have dependencies
	  - carthage bootstrap
	before_deploy:
	  - carthage build --no-skip-current
	  - carthage archive $FRAMEWORK_NAME
	```
1. Run `travis setup releases`, follow documentation [here](https://docs.travis-ci.com/user/deployment/releases/)

	This command will encode your GitHub credentials into the `.travis.yml` file in order to let travis upload the release to GitHub.com
	When prompted for the file to upload, enter `$FRAMEWORK_NAME.framework.zip`

1. Update the deploy section to run on tags:

	In `.travis.yml` locate:

	```YAML
	on:
	  repo: repo/repo
	```

	And add `tags: true` and `skip_cleanup: true`:

	```YAML
	skip_cleanup: true
	on:
	  repo: repo/repo
	  tags: true
	```

	That will let travis know to create a deployment when a new tag is pushed and prevent travis to cleanup the generated zip file

### Build static frameworks to speed up your app’s launch times

If you embed many dynamic frameworks into your app, its pre-main launch times may be quite slow. Carthage is able to help mitigate this by building your dynamic frameworks as static frameworks instead. Static frameworks can be linked directly into your application or merged together into a larger dynamic framework with a few simple modifications to your workflow, which can result in dramatic reductions in pre-main launch times.

#### Carthage 0.30.0 or higher

Since version 0.30.0 Carthage project rolls out support for statically linked frameworks written in Swift or Objective-C, support for which has been introduced in Xcode 9.4. Please note however that it specifically says *frameworks*, hence Darwin bundles with **.framework** extension and statically linked object archives inside. Carthage does not currently support static *library* schemes, nor are there any plans to introduce their support in the future.

The workflow differs barely:

- You still need to tick your Carthage-compliant project's schemes as *shared* in *Product > Scheme > Manage Schemes...*, just as with dynamic binaries
- You still need to link against static **.frameworks** in your project's *Build Phases* just as with dynamic binaries

However:

- In your Carthage-compliant project's Cocoa Framework target's *Build Settings*, *Linking* section, set **Mach-O Type** to **Static Library**
- Your statically linked frameworks will be built at *./Carthage/Build/$(PLATFORM_NAME)/Static*
- You should not add any of static frameworks as input/output files in **carthage copy-frameworks** *Build Phase*

#### Carthage 0.29.0 or lower

See the [StaticFrameworks][StaticFrameworks] doc for details.

*Please note that a few caveats apply to this approach:*
- Swift static frameworks are not officially supported by Apple
- This is an advanced workflow that is not built into Carthage, YMMV

### Declare your compatibility

Want to advertise that your project can be used with Carthage? You can add a compatibility badge:

[![Carthage compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage)

… to your `README`, by simply inserting the following Markdown:

```markdown
[![Carthage compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage)
```
## CarthageKit

Most of the functionality of the `carthage` command line tool is actually encapsulated in a framework named CarthageKit.

If you’re interested in using Carthage as part of another tool, or perhaps extending the functionality of Carthage, take a look at the [CarthageKit][] source code to see if the API fits your needs.

## Differences between Carthage and CocoaPods

[CocoaPods](http://cocoapods.org/) is a long-standing dependency manager for Cocoa. So why was Carthage created?

Firstly, CocoaPods (by default) automatically creates and updates an Xcode workspace for your application and all dependencies. Carthage builds framework binaries using `xcodebuild`, but leaves the responsibility of integrating them up to the user. CocoaPods’ approach is easier to use, while Carthage’s is flexible and unintrusive.

The goal of CocoaPods is listed in its [README](https://github.com/CocoaPods/CocoaPods/blob/1703a3464674baecf54bd7e766f4b37ed8fc43f7/README.md) as follows:

> … to improve discoverability of, and engagement in, third party open-source libraries, by creating a more centralized ecosystem.

By contrast, Carthage has been created as a _decentralized_ dependency manager. There is no central list of projects, which reduces maintenance work and avoids any central point of failure. However, project discovery is more difficult—users must resort to GitHub’s [Trending](https://github.com/trending?l=swift) pages or similar.

CocoaPods projects must also have what’s known as a [podspec](http://guides.cocoapods.org/syntax/podspec.html) file, which includes metadata about the project and specifies how it should be built. Carthage uses `xcodebuild` to build dependencies, instead of integrating them into a single workspace, it doesn’t have a similar specification file but your dependencies must include their own Xcode project that describes how to build their products.

Ultimately, we created Carthage because we wanted the simplest tool possible—a dependency manager that gets the job done without taking over the responsibility of Xcode, and without creating extra work for framework authors. CocoaPods offers many amazing features that Carthage will never have, at the expense of additional complexity.

## License

Carthage is released under the [MIT License](LICENSE.md).

Header backdrop photo is released under the [CC BY-NC-SA 2.0](https://creativecommons.org/licenses/by-nc-sa/2.0/) license. Original photo by [Richard Mortel](https://www.flickr.com/photos/prof_richard/).

[Artifacts]: Documentation/Artifacts.md
[Cartfile]: Documentation/Artifacts.md#cartfile
[Cartfile.resolved]: Documentation/Artifacts.md#cartfileresolved
[Carthage/Build]: Documentation/Artifacts.md#carthagebuild
[Carthage/Checkouts]: Documentation/Artifacts.md#carthagecheckouts
[Bash/Zsh/Fish Completion]: Documentation/BashZshFishCompletion.md
[CarthageKit]: Source/CarthageKit
[VersionFile]: Documentation/VersionFile.md
[StaticFrameworks]: Documentation/StaticFrameworks.md

