// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ephedrine",
    platforms: [.macOS("14.4")],   // NSMenuItem.subtitle requires 14.4
    targets: [
        .target(name: "EphedrineCore"),
        .executableTarget(name: "Ephedrine", dependencies: ["EphedrineCore"]),
        .testTarget(name: "EphedrineCoreTests", dependencies: ["EphedrineCore"]),
    ]
)
