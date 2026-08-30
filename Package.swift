// swift-tools-version:5.9
import PackageDescription

/// Portable core tests do not require MLX, Qwen, StoreKit, or an OpenAI key.
let package = Package(
    name: "VoiceNotesCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "VoiceNotesCore", targets: ["WalkWrite"])],
    targets: [
        .target(
            name: "WalkWrite",
            path: "WalkWrite",
            exclude: [
                "Assets.xcassets", "Info.plist", "PrivacyInfo.xcprivacy",
                "ggml-large-v3-turbo-encoder.mlmodelc", "ggml-large-v3-turbo-q5_0.bin",
                "WalkAndWriteLogo.png"
            ],
            sources: [
                "AIModels.swift", "AppFolders.swift", "Note.swift", "NoteStore.swift",
                "WhisperModelManager.swift", "WhisperStateManager.swift"
            ]
        ),
        .testTarget(
            name: "WalkWriteCoreTests",
            dependencies: ["WalkWrite"],
            path: "WalkWriteTests",
            exclude: ["AIControllerTests.swift", "BackendClientTests.swift"],
            sources: ["AudioSafetyTests.swift", "NoteStoreTests.swift"]
        )
    ]
)
