// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoteMD",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NoteMD", targets: ["NoteMD"]),
    ],
    dependencies: [
        // cmark-gfm: GitHub's Markdown engine (tables, task lists, autolinks, tagfilter).
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.9.0"),
        // De-facto Swift YAML library, used for note front matter.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(
            name: "NoteMDCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/NoteMDCore"
        ),
        .executableTarget(
            name: "NoteMD",
            dependencies: ["NoteMDCore"],
            path: "Sources/NoteMD",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Share menu extension, assembled into Contents/PlugIns/NoteMDShare.appex by build-app.sh.
        .executableTarget(
            name: "NoteMDShare",
            path: "Sources/NoteMDShare",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-application-extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(
            name: "NoteMDCoreTests",
            dependencies: ["NoteMDCore"],
            path: "Tests/NoteMDCoreTests"
        ),
    ]
)
