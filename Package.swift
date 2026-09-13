// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "lm15-swift",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11)],
    products: [.library(name: "LM15", targets: ["LM15"]), .executable(name: "lm15-vet", targets: ["LM15Vet"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"), .package(url: "https://github.com/apple/swift-nio.git", exact: "2.81.0"), .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.31.0")],
    targets: [
        .target(name: "CProcess"),
        .target(name: "LM15", dependencies: [.product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.linux])), .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.linux])), .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.linux])), .product(name: "NIOWebSocket", package: "swift-nio", condition: .when(platforms: [.linux])), .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux])), "CProcess",.product(name: "Crypto", package: "swift-crypto"), .product(name: "_CryptoExtras", package: "swift-crypto")], resources: [.process("Resources")]),
        .executableTarget(name: "LM15Vet", dependencies: ["LM15"]),
        .executableTarget(name: "LM15Example", dependencies: ["LM15"], path: "Examples/Offline"),
        .testTarget(name: "LM15Tests", dependencies: ["LM15", .product(name: "Crypto", package: "swift-crypto")])
    ]
)
