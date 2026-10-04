import XCTest
import CryptoKit
@testable import Sift

final class LocalModelBundleTests: XCTestCase {
    private func fixture(model: String = SemanticPolicy.modelID, revision: String = SemanticPolicy.modelRevision) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"].map { name -> [String: Any] in
            let data = Data("local-test-file-\(name)".utf8)
            try data.write(to: root.appendingPathComponent(name))
            return ["name": name, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        try JSONSerialization.data(withJSONObject: ["model": model, "revision": revision, "files": files])
            .write(to: root.appendingPathComponent("manifest.json"))
        return root
    }

    func testPinnedQwenIdentityAndDeduplicationVersion() {
        XCTAssertEqual(SemanticPolicy.modelID, "local/Sift-Qwen3-0.6B-QLoRA")
        XCTAssertEqual(SemanticPolicy.modelRevision, "7252e5c48ad95c76ed8900027d4df16f49a588ef966d1cef654b6af6db1e5a5a")
        XCTAssertTrue(SemanticPolicy.version.hasPrefix("sift-qwen3-0.6b-qlora-"))
        XCTAssertTrue(SemanticPolicy.version.contains(SemanticPolicy.rulesVersion))
        XCTAssertEqual(LocalModelIdentity.bundled.license, "Apache-2.0")
    }

    func testLocalChecksumVerificationAndTampering() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrow(try LocalModelEngine.verifyBundle(root))
        try Data("modified".utf8).write(to: root.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try LocalModelEngine.verifyBundle(root))
    }

    func testExperimentalLFMBundleCannotLoadAsQwen() throws {
        let root = try fixture(model: "mlx-community/LFM2.5-1.2B-Instruct-4bit", revision: "dee2f8a2786e6648bb644a7ca40652842490034b")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try LocalModelEngine.verifyBundle(root))
    }

    func testWrongRevisionOrMissingFileFailsVerification() throws {
        let wrong = try fixture(revision: "wrong-revision")
        let missing = try fixture()
        defer { try? FileManager.default.removeItem(at: wrong); try? FileManager.default.removeItem(at: missing) }
        XCTAssertThrowsError(try LocalModelEngine.verifyBundle(wrong))
        try FileManager.default.removeItem(at: missing.appendingPathComponent("tokenizer.json"))
        XCTAssertThrowsError(try LocalModelEngine.verifyBundle(missing))
    }

    func testDirectExtractionUsesCurrentModelPolicyVersion() async throws {
        let document = OCRDocument(rawText: "取餐码 A057\n街角咖啡", blocks: [
            OCRBlock(text: "取餐码 A057", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.04), confidence: 0.99),
            OCRBlock(text: "街角咖啡", boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.04), confidence: 0.99)
        ], recognitionLanguage: "zh-Hans", engineVersion: "test")
        let engine = LocalModelEngine(directory: nil)
        guard case .accepted(let item) = try await engine.evaluate(document: document) else { return XCTFail("Expected grounded pickup") }
        XCTAssertEqual(item.classificationVersion, SemanticPolicy.version)
        XCTAssertEqual(item.code, "A057")
        await engine.release()
    }
}
