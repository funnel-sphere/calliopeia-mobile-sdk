// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CalliopeiaMobileSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CalliopeiaAudioContracts", targets: ["CalliopeiaAudioContracts"]),
        .library(name: "CalliopeiaAudioCapture", targets: ["CalliopeiaAudioCapture"]),
        .library(name: "CalliopeiaSDK", targets: ["CalliopeiaSDK"]),
    ],
    targets: [
        .target(
            name: "CalliopeiaAudioContracts",
            path: "ios/Sources/CalliopeiaAudioContracts"
        ),
        .target(
            name: "CalliopeiaAudioCapture",
            dependencies: ["CalliopeiaAudioContracts"],
            path: "ios/Sources/CalliopeiaAudioCapture",
            linkerSettings: [
                .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "CalliopeiaSDK",
            dependencies: ["CalliopeiaAudioContracts", "CalliopeiaAudioCapture"],
            path: "ios/Sources/CalliopeiaSDK",
            linkerSettings: [
                .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "CalliopeiaSDKTests",
            dependencies: ["CalliopeiaSDK"],
            path: "ios/Tests/CalliopeiaSDKTests"
        ),
    ]
)
