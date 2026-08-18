// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VelaPrivilegedModules",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VelaIPC", targets: ["VelaIPC"]),
        .library(name: "VelaPrivilegedCore", targets: ["VelaPrivilegedCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .target(
            name: "VelaIPC",
            path: ".",
            exclude: ["Sources", "Tests"],
            sources: [
                "CoreLifecycleDTOs.swift",
                "CoreCatalogTrust.swift",
                "HelperDTOs.swift",
                "HelperPayloadCodec.swift",
                "SecretValue.swift",
                "TunSettings.swift",
                "VelaHelperError.swift",
                "VelaHelperProtocol.swift",
                "VelaIPCConstants.swift",
            ]
        ),
        .target(
            name: "VelaPrivilegedCore",
            dependencies: [
                "VelaIPC",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/VelaPrivilegedCore"
        ),
        .testTarget(
            name: "VelaIPCTests",
            dependencies: ["VelaIPC"],
            path: "Tests/VelaIPCTests"
        ),
        .testTarget(
            name: "VelaPrivilegedCoreTests",
            dependencies: [
                "VelaIPC",
                "VelaPrivilegedCore",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Tests/VelaPrivilegedCoreTests"
        ),
    ]
)
