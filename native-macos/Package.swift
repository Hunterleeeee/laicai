// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LaicaiNative",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "LaicaiNativeApp", targets: ["LaicaiNativeApp"]),
        .library(name: "LaicaiNativeDomain", targets: ["LaicaiNativeDomain"]),
        .library(name: "LaicaiNativeFoundation", targets: ["LaicaiNativeFoundation"]),
        .library(name: "LaicaiNativeUI", targets: ["LaicaiNativeUI"]),
    ],
    targets: [
        .target(name: "LaicaiNativeDomain"),
        .target(name: "LaicaiNativeFoundation", dependencies: ["LaicaiNativeDomain"]),
        .target(name: "LaicaiNativeUI", dependencies: ["LaicaiNativeDomain", "LaicaiNativeFoundation"]),
        .executableTarget(name: "LaicaiNativeApp", dependencies: ["LaicaiNativeUI", "LaicaiNativeFoundation"]),
        .testTarget(name: "LaicaiNativeFoundationTests", dependencies: ["LaicaiNativeFoundation", "LaicaiNativeDomain"]),
    ]
)
