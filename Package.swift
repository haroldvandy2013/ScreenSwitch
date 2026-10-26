// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ScreenSwitch", targets: ["ScreenSwitch"])],
    targets: [
        .target(name: "ScreenSwitchCore"),
        .executableTarget(name: "ScreenSwitch", dependencies: ["ScreenSwitchCore"]),
        .executableTarget(
            name: "ScreenSwitchChecks",
            dependencies: ["ScreenSwitchCore"],
            path: "Tests/ScreenSwitchChecks"
        )
    ],
    swiftLanguageModes: [.v5]
)
