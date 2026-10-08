// swift-tools-version: 6.2
import PackageDescription

// Developer evaluation tool; the iPhone app is built from project.yml.
let package = Package(
    name: "SiftLocalEvaluation",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0")
    ],
    targets: [.executableTarget(name: "SiftEvaluate", dependencies: [
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ], path: ".", exclude: ["Tests", "UITests", "Scripts", "Design", "Sift.xcodeproj", "Sift/Resources", "Sift/SiftApp.swift", "Sift/BackgroundScan.swift", "Sift/Info.plist", "Sift/Sift.entitlements", "Sift/SiftForeground.entitlements", "Sift/SettingsView.swift", "Sift/ReprocessingView.swift", "Sift/LocalServices.swift", "Sift/DesignSystem.swift", "Sift/ScreenshotScan.swift", "Sift/ScreenshotScanSheet.swift", "Sift/CardStacks.swift", "Sift/ScreenshotViewer.swift", "Sift/PreviewLaunchOptions.swift", "README.md", "ARCHITECTURE.md", "project.yml", "default.profraw", "Evaluation/grounded_cases.json", "Evaluation/synthetic_cases.json", "Evaluation/schedule_cases.json", "Evaluation/README.md", "Evaluation/results"], sources: ["Sift/Domain.swift", "Sift/Reprocessing.swift", "Sift/PickupStoreResolver.swift", "Sift/RecognitionPolicy.swift", "Sift/SemanticExtraction.swift", "Sift/LocalModelEngine.swift", "Sift/GroundedExtraction.swift", "Sift/SelectionInput.swift", "Sift/ScheduleAdmission.swift", "Evaluation/Runner.swift"])],
    swiftLanguageModes: [.v5]
)
