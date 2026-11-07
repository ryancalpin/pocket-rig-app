// swift-tools-version:6.2
import PackageDescription

let mcc = "moonlight-common-c"
let package = Package(
    name: "MoonlightCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "CMoonlight", targets: ["CMoonlight"])],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", exact: "3.6.5000"),
    ],
    targets: [
        .target(
            name: "CMoonlight",
            dependencies: [.product(name: "OpenSSL", package: "OpenSSL-Package")],
            path: "Sources/CMoonlight",
            exclude: [
                "\(mcc)/CMakeLists.txt", "\(mcc)/cmake", "\(mcc)/README.md", "\(mcc)/LICENSE.txt",
                "\(mcc)/enet/CMakeLists.txt", "\(mcc)/enet/win32.c",
                "\(mcc)/nanors/rs16.c", "\(mcc)/nanors/rs16_afft.c",
            ],
            sources: [
                "\(mcc)/src",
                "\(mcc)/enet/callbacks.c", "\(mcc)/enet/compress.c", "\(mcc)/enet/host.c",
                "\(mcc)/enet/list.c", "\(mcc)/enet/packet.c", "\(mcc)/enet/peer.c",
                "\(mcc)/enet/protocol.c", "\(mcc)/enet/unix.c",
                "\(mcc)/nanors/rs.c", "\(mcc)/nanors/deps/obl/oblas_common.c", "\(mcc)/nanors/deps/obl/oblas_lite.c",
                "PRBridge.c", "PRCrypto.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("\(mcc)/src"),
                .headerSearchPath("\(mcc)/enet/include"),
                .headerSearchPath("\(mcc)/nanors"),
                .headerSearchPath("\(mcc)/nanors/deps"),
                .headerSearchPath("\(mcc)/nanors/deps/obl"),
                .headerSearchPath("openssl-shim"),
                .define("NDEBUG"),
                .define("HAS_SOCKLEN_T"), .define("HAS_FCNTL"), .define("HAS_IOCTL"), .define("HAS_POLL"),
                .define("HAS_GETADDRINFO"), .define("HAS_GETNAMEINFO"), .define("HAS_INET_PTON"),
                .define("HAS_INET_NTOP"), .define("HAS_MSGHDR_FLAGS"),
                .unsafeFlags(["-Wno-unused-parameter", "-Wno-shorten-64-to-32", "-Wno-conversion", "-Wno-non-modular-include-in-framework-module"]),
            ]
        ),
    ]
)
