// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UCASCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "UCASCore", targets: ["UCASCore"])],
    targets: [
        .target(name: "UCASCore", path: "UCASSignIn/Core"),
        .testTarget(name: "UCASCoreTests", dependencies: ["UCASCore"], path: "Tests/UCASCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
