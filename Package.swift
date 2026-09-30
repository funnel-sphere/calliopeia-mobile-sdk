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
        .library(name: "CalliopeiaAuth", targets: ["CalliopeiaAuth"]),
    ],
    dependencies: [
        .package(url: "https://github.com/aws-amplify/amplify-swift", exact: "2.58.1"),
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
                .linkedFramework("AVFoundation", .when(platforms: [.iOS, .macOS])),
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
        .target(
            name: "CalliopeiaAuth",
            dependencies: [
                "CalliopeiaSDK",
                .product(name: "Amplify", package: "amplify-swift"),
                .product(name: "AWSCognitoAuthPlugin", package: "amplify-swift"),
                .product(name: "AWSPluginsCore", package: "amplify-swift"),
            ],
            path: "ios/Sources/CalliopeiaAuth"
        ),
        .testTarget(
            name: "CalliopeiaSDKTests",
            dependencies: [
                "CalliopeiaSDK",
                "CalliopeiaAudioCapture",
                "CalliopeiaAudioContracts",
            ],
            path: "ios/Tests/CalliopeiaSDKTests"
        ),
    ]
)
