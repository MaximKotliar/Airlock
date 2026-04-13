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
                dependencies: [.Internal.libAirlock],
                exclude: [Name.libAirlock]),
        .target(
            name: Name.libAirlock,
            path: "Sources/\(Name.airlock)/\(Name.libAirlock)"
        ),
        .testTarget(name: Name.airlockTests,
                    dependencies: [.Internal.airlock]),
        .executableTarget(name: "Tool",
                          dependencies: [.Internal.airlock]),
        .executableTarget(name: Name.testHelper,
                          dependencies: [.Internal.airlock])
    ]
)

// MARK: - String Constants
enum Name {
    static let airlock = "Airlock"
    static let libAirlock = "libAirlock"
    static let airlockTests = "AirlockTests"
    static let testHelper = "TestHelper"
}

// MARK: - Target Dependencies
extension Target.Dependency {
    enum Internal {
        static let airlock: Target.Dependency = .byName(name: Name.airlock)
        static let libAirlock: Target.Dependency = .byName(name: Name.libAirlock)
        static let testHelper: Target.Dependency = .byName(name: Name.testHelper)
    }
}
