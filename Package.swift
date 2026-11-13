// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SilTerm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SilTerm", targets: ["SilTerm"])
    ],
    targets: [
        // 内置的 libvterm（C 源码），无外部依赖，保证离线可编译
        .target(
            name: "CVTerm",
            path: "Sources/CVTerm",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ]
        ),
        // PTY / 进程工作目录等系统调用封装
        .target(
            name: "CShim",
            path: "Sources/CShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SilTermCore",
            dependencies: ["CVTerm", "CShim"],
            path: "Sources/SilTermCore"
        ),
        .executableTarget(
            name: "SilTerm",
            dependencies: ["SilTermCore"],
            path: "Sources/SilTerm",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("CoreServices")
            ]
        )
    ]
)
