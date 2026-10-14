// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "client-app",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClientAppKit", targets: ["ClientAppKit"]),
        .executable(name: "client-app", targets: ["client-app"]),
    ],
    targets: [
        // Sign-in through the browser (OAuth + PKCE) and direct uploads to Azure
        .target(name: "ClientAppKit"),
        // The command line: client-app login | upload | folders | publish... | delete | logout
        .executableTarget(name: "client-app", dependencies: ["ClientAppKit"]),
        .testTarget(name: "ClientAppKitTests", dependencies: ["ClientAppKit"]),
    ]
)
