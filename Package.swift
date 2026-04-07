// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.


import PackageDescription

// MARK: - Package Description
// macOS only (`fork`); minimum 12 = POSIX + Foundation only, no newer SDK calls required.
let package = Package(
    name: "\(Name.airlock)",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: Name.airlock, targets: [Name.airlock])
    ],
    targets: [
        .target(name: Name.airlock,
                dependencies: [.Internal.shims],
                exclude: [Name.shims]),
        .target(
            name: Name.shims,
            path: "Sources/\(Name.airlock)/\(Name.shims)"
        ),
        .testTarget(name: Name.airlockTests,
                    dependencies: [.Internal.airlock])
    ]
)

// MARK: - String Constants
enum Name {
    static let airlock = "Airlock"
    static let shims = "Shims"
    static let airlockTests = "AirlockTests"
}

// MARK: - Target Dependencies
extension Target.Dependency {
    enum Internal {
        static let airlock: Target.Dependency = .byName(name: Name.airlock)
        static let shims: Target.Dependency = .byName(name: Name.shims)
    }
}
