// swift-tools-version:5.9
import PackageDescription

// Проект для VS Code / командной строки: `swift build` без Xcode-проекта.
// Готовое приложение (.app) собирает ./build_app.sh
let package = Package(
    name: "SnowfallMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SnowfallMac", targets: ["SnowfallMac"])
    ],
    targets: [
        .executableTarget(
            name: "SnowfallMac",
            path: "SnowfallMac/Sources"
        )
    ]
)
