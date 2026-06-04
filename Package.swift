// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Aozora",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Aozora",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "DequeModule", package: "swift-collections"),
            ],
            path: ".",
            exclude: [
                // Xcode project files
                "Aozora.xcodeproj",
                "AozoraTests",
                "Package.swift",
                "scripts",
                ".build",
                ".swiftpm",
                ".git",
                ".gitignore",
                // Xcode app target (not part of SPM build)
                "Aozora",
                // AozoraCore boilerplate
                "AozoraCore/AozoraCore.swift",
                "AozoraCore/AozoraCore.docc",
                // Documentation
                "CLAUDE.md",
                "README.md",
                "ARCHITECTURE.md",
            ],
            sources: [
                "AozoraCore/Auth",
                "AozoraCore/CIMS",
                "AozoraCore/IPC",
                "AozoraCore/Utilities",
                "Daemon",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "AozoraTests",
            dependencies: ["Aozora"],
            path: "AozoraTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
    ],
)
