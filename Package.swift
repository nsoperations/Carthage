// swift-tools-version:4.2
import PackageDescription

let package = Package(
    name: "Carthage",
    products: [
        .library(name: "XCDBLD", targets: ["XCDBLD"]),
        .library(name: "CarthageKit", targets: ["CarthageKit"]),
        .executable(name: "carthage", targets: ["carthage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/antitypical/Result.git", from: "4.1.0"),
        .package(url: "https://github.com/nsoperations/Commandant.git", .branch("feature/success-handler")),
        .package(url: "https://github.com/jdhealy/PrettyColors.git", from: "5.0.2"),
        .package(url: "https://github.com/ReactiveCocoa/ReactiveSwift.git", from: "5.0.0"),
        .package(url: "https://github.com/mdiep/Tentacle.git", from: "0.13.1"),
        .package(url: "https://github.com/thoughtbot/Curry.git", from: "4.0.2"),
        .package(url: "https://github.com/nsoperations/BTree.git", from: "4.1.1"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "2.0.0"),
        .package(url: "https://github.com/Quick/Quick.git", from: "2.1.0"),
        .package(url: "https://github.com/Quick/Nimble.git", from: "8.1.2"),
    ],
    targets: [
        .target(
            name: "XCDBLD",
            dependencies: ["Result", "ReactiveSwift", "ReactiveTask"]
        ),
        .testTarget(
            name: "XCDBLDTests",
            dependencies: ["XCDBLD", "Nimble"]
        ),
        .target(
            name: "CarthageKit",
            dependencies: ["XCDBLD", "Tentacle", "Curry", "BTree", "wildmatch", "ReactiveTask", "Yams"]
        ),
        .testTarget(
            name: "CarthageKitTests",
            dependencies: ["CarthageKit", "Quick", "Nimble"],
            exclude: ["Resources/FakeOldObjc.framework"]
        ),
        .target(
            name: "carthage",
            dependencies: ["XCDBLD", "CarthageKit", "Commandant", "Curry", "PrettyColors"],
            exclude: ["swift-is-crashy.c"]
        ),
	.target(
            name: "ReactiveTask",
            dependencies: ["ReactiveSwift", "Result"]
        ),
        .target(
            name: "wildmatch"
        ),
    ],
    swiftLanguageVersions: [.v4_2]
)
