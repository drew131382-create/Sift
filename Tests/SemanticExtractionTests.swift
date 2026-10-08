import XCTest
@testable import Sift

final class SemanticExtractionTests: XCTestCase {
    private func doc(_ lines: [String]) -> OCRDocument {
        OCRDocument(rawText: lines.joined(separator: "\n"), blocks: lines.map { OCRBlock(text: $0, boundingBox: .zero, confidence: 0.95) }, recognitionLanguage: "zh-Hans", engineVersion: "synthetic")
    }
    private func field(_ kind: FieldKind, _ value: String?, _ sources: [Int]) -> SemanticField { SemanticField(kind: kind.rawValue, value: value, sources: sources) }
    private func evaluate(_ scene: SemanticScene, _ document: OCRDocument) throws -> InformationItem {
        let decision = try SemanticValidator.evaluate(SemanticResponse(scenes: [scene]), document: document, blocks: document.blocks)
        guard case .accepted(let item) = decision else { throw SemanticError.invalidOutput }
        return item
    }
    func testImplicitCollectionCodeRequiresEvidence() throws {
        let document = doc(["您的包裹已到店", "请凭8-3021领取包裹", "静安驿站"])
        let scene = SemanticScene(category: "delivery", title: "静安驿站取件", needsReview: false, evidence: [0,1], fields: [field(.code, "8-3021", [1]), field(.parcelStation, "静安驿站", [2])])
        let item = try evaluate(scene, document)
        XCTAssertEqual(item.code, "8-3021"); XCTAssertEqual(item.state, .pending)
        var invented = scene; invented.fields[0].value = "8-3022"
        let rejected = try evaluate(invented, document)
        XCTAssertEqual(rejected.code, ""); XCTAssertEqual(rejected.state, .needsReview)
    }
    func testAmountsCannotComeFromOriginalDiscountBalanceOrRefund() throws {
        for label in ["原价", "优惠", "余额", "退款", "待付", "应付", "单价"] {
            let document = doc(["实付金额：24.00", "\(label)：100.00", "街角咖啡"])
            let scene = SemanticScene(category: "payment", title: "咖啡付款", needsReview: false, evidence: [0], fields: [field(.amount, "100.00", [0,1]), field(.merchant, "街角咖啡", [2])])
            let item = try evaluate(scene, document)
            XCTAssertEqual(item.amount, "", label); XCTAssertEqual(item.state, .needsReview)
        }
    }
    func testWrongCitationCanOnlyBeRepairedWithUniqueLiteralEvidence() throws {
        let document = doc(["包裹到了", "请凭8-3021领取包裹", "驿站"])
        var scene = SemanticScene(category: "delivery", title: "取件", needsReview: false, evidence: [0,1], fields: [field(.code, "8-3021", [0])])
        let repaired = try evaluate(scene, document)
        XCTAssertEqual(repaired.code, "8-3021")
        XCTAssertEqual(repaired.state, .needsReview)
        XCTAssertEqual(repaired.fields.first?.sourceBlockIDs, [document.blocks[1].id])
        scene.fields[0].value = "8-3022"
        XCTAssertEqual(try evaluate(scene, document).code, "")
        let ambiguous = doc(["包裹到了", "请凭8-3021领取包裹", "订单号：8-3021"])
        scene.fields[0].value = "8-3021"
        XCTAssertEqual(try evaluate(scene, ambiguous).code, "")
    }
    func testNumericSubstringsAndStatusAttachedToBusinessCannotBeUsed() throws {
        let document = doc(["取件码：123456", "实付：124.00", "咖啡店"])
        let code = SemanticScene(category: "delivery", title: "取件", needsReview: false, evidence: [0], fields: [field(.code, "123", [0])])
        XCTAssertEqual(try evaluate(code, document).code, "")
        let payment = SemanticScene(category: "payment", title: "支付", needsReview: false, evidence: [1], fields: [field(.amount, "24.00", [1])])
        XCTAssertEqual(try evaluate(payment, document).amount, "")
        var status = doc(["09:41", "牙科复诊预约已确认"])
        status.blocks[0].boundingBox = CGRect(x: 0, y: 0.96, width: 0.1, height: 0.02)
        let event = SemanticScene(category: "event", title: "复诊", needsReview: false, evidence: [1], fields: [field(.eventTime, "09:41", [0,1])], scheduleEvidence: ScheduleEvidence(kind: .confirmedReservation, sources: [1]))
        XCTAssertFalse(try evaluate(event, status).fields.contains { $0.kind == .eventTime })
    }
    func testGeneratedSchemaIsJSONAndRestrictsCategoryAndSourceIDs() throws {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(SemanticPolicy.schema(sourceIDs: [3,7]).utf8)) as? [String: Any])
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        XCTAssertTrue(SemanticPolicy.schema(sourceIDs: [3,7]).contains("\"enum\":[3,7]"))
        XCTAssertFalse(SemanticValidator.fieldKinds(.delivery).contains(.documentReference))
        XCTAssertFalse(SemanticValidator.fieldKinds(.payment).contains(.code))
    }
    func testSensitiveSchemaUsesVerbatimSpansWithoutInventingTime() {
        let texts = ["取件码：A057", "原价100.00 实付24.00 余额500.00", "就诊时间：2026年10月3日 09:30"]
        XCTAssertTrue(SemanticPolicy.literalValues(.code, texts: texts).contains("A057"))
        XCTAssertTrue(SemanticPolicy.literalValues(.amount, texts: texts).contains("24.00"))
        let times = SemanticPolicy.literalValues(.eventTime, texts: texts)
        XCTAssertTrue(times.contains("2026年10月3日 09:30"))
        XCTAssertFalse(times.contains("2026年10月3日 次日09:30"))
        XCTAssertFalse(SemanticPolicy.literalValues(.time, texts: texts).contains("21:30"))
        XCTAssertTrue(SemanticPolicy.literalValues(.documentReference, texts: ["发票号码 INV-2026-100"]).contains("INV-2026-100"))
    }
    func testDocumentReferencesCannotBeInvoiceTitlesOrParties() throws {
        let document = doc(["电子发票", "发票号码 INV-2026-100", "购买方 上海公司"])
        let scene = SemanticScene(category: "documentation", title: "发票", needsReview: false, evidence: [0,1], fields: [field(.documentReference, "电子发票", [0]), field(.documentReference, "上海公司", [2]), field(.documentReference, "INV-2026-100", [1])])
        XCTAssertEqual(try evaluate(scene, document).fields.first(where: { $0.kind == .documentReference })?.value, "INV-2026-100")
    }
    func testSuccessAmountCanUseSceneEvidenceAndDeadlineNeedsTemporalEvidence() throws {
        let document = doc(["支付成功", "24.00", "咖啡店", "原价100.00"])
        let scene = SemanticScene(category: "payment", title: "支付", needsReview: false, evidence: [0], fields: [field(.amount, "24.00", [0,1]), field(.merchant, "咖啡店", [2])])
        XCTAssertEqual(try evaluate(scene, document).amount, "24.00")
        let pickup = doc(["取件码A123", "请明天20:00前领取", "南门驿站"])
        var delivery = SemanticScene(category: "delivery", title: "领取", needsReview: false, evidence: [0,1], fields: [field(.code, "A123", [0]), field(.deadline, "请明天20:00前领取", [1])])
        XCTAssertNotNil(try evaluate(delivery, pickup).fields.first(where: { $0.kind == .deadline }))
        delivery.fields[1] = field(.deadline, "南门驿站", [2])
        XCTAssertNil(try evaluate(delivery, pickup).fields.first(where: { $0.kind == .deadline }))
    }
    @MainActor func testManualBatchIsPersistedBeforePauseAndRecoversWithoutScanning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        weak var pausedStore: SiftStore?
        let store = SiftStore(repository: repository, recognize: { _ in self.doc(["取件码：A123"]) }, extract: { _ in
            pausedStore?.setForeground(false)
            throw SemanticError.interrupted
        }, resumePendingJobs: false)
        pausedStore = store
        await store.importImages([Data("one".utf8), Data("two".utf8), Data("three".utf8)])
        XCTAssertEqual(try repository.loadJobs().count, 3)
        XCTAssertTrue(try repository.loadScanRecords().isEmpty)
        let restored = SiftStore(repository: repository, fetchAssets: { _ in XCTFail("Recovery must not fetch a new album range"); return [] }, recognize: { _ in self.doc(["取件码：A123"]) }, extract: { document in
            try SemanticValidator.evaluate(SemanticResponse(scenes: [SemanticScene(category: "delivery", title: "取件", needsReview: false, evidence: [0], fields: [self.field(.code, "A123", [0])])]), document: document, blocks: document.blocks)
        })
        for _ in 0..<100 where !restored.jobs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(restored.jobs.isEmpty)
        XCTAssertEqual(restored.items.count, 3)
    }
    func testModelMissingAndInvalidOutputStayRetryable() async throws {
        let engine = LocalModelEngine(directory: nil)
        do { _ = try await engine.evaluate(document: doc(["这是一段需要模型理解的文学摘录，保留文字供以后阅读。"])) ; XCTFail("Missing model should fail") }
        catch { XCTAssertTrue(error is SemanticError) }
        XCTAssertThrowsError(try evaluate(SemanticScene(category: "delivery", title: "取件", needsReview: false, evidence: [999], fields: []), doc(["取件码A123"])))
    }
    func testConflictingCodesAndAmountsAreBlank() throws {
        for (category, kind, lines, values) in [("delivery", FieldKind.code, ["取件码：A123", "取件码：B456"], ["A123", "B456"]), ("payment", .amount, ["实付：24.00", "实付：26.00"], ["24.00", "26.00"])] {
            let document = doc(lines)
            let scene = SemanticScene(category: category, title: "信息", needsReview: false, evidence: [0], fields: [field(kind, values[0], [0])])
            let item = try evaluate(scene, document)
            XCTAssertFalse(item.fields.contains { $0.kind == kind }); XCTAssertEqual(item.state, .needsReview)
        }
    }
    func testStatusTimeAndInvalidCalendarDateAreRejected() throws {
        var document = doc(["09:41", "牙科复诊预约已确认", "2026年2月30日 10:00"])
        document.blocks[0].boundingBox = CGRect(x: 0.1, y: 0.96, width: 0.1, height: 0.02)
        for (value, source) in [("09:41", 0), ("2026年2月30日 10:00", 2)] {
            let scene = SemanticScene(category: "event", title: "预约", needsReview: false, evidence: [1], fields: [field(.eventName, "牙科复诊", [1]), field(.eventTime, value, [source])], scheduleEvidence: ScheduleEvidence(kind: .confirmedReservation, sources: [1]))
            let item = try evaluate(scene, document)
            XCTAssertFalse(item.fields.contains { $0.kind == .eventTime }); XCTAssertEqual(item.state, .needsReview)
        }
    }
    func testLongSingleBlockIncludesTailAndMergesConflicts() {
        let text = String(repeating: "普通文字", count: 3000) + "请凭8-3021领取包裹"
        let chunks = SemanticInput.chunks(doc([text]).blocks)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.last!.contains { $0.text.contains("8-3021") })
        XCTAssertTrue(chunks.flatMap { $0 }.allSatisfy { $0.id == 0 })
        let a = SemanticScene(category: "delivery", title: "取件", needsReview: false, evidence: [0], fields: [field(.code, "A123", [0])])
        var b = a; b.fields[0].value = "B456"
        XCTAssertEqual(SemanticInput.merge([SemanticResponse(scenes: [a]), SemanticResponse(scenes: [b])]).scenes[0].fields.count, 2)
    }
    func testFiveGroupsPreserveHistoricalCategories() {
        XCTAssertEqual(CategoryGroup.allCases.count, 5)
        XCTAssertEqual(Sift.Category.delivery.group, .collectionCodes)
        XCTAssertEqual(Sift.Category.health.group, .schedules)
        XCTAssertEqual(Sift.Category.documentation.group, .purchases)
        XCTAssertEqual(Sift.Category.social.group, .conversations)
        XCTAssertEqual(Sift.Category.other.group, .collections)
    }
    func testMultipleScenesChooseCodesAndRequireConfirmation() throws {
        let document = doc(["请凭8-3021领取包裹", "街角咖啡", "实付：24.00"])
        let a = SemanticScene(category: "payment", title: "咖啡", needsReview: false, evidence: [1,2], fields: [field(.merchant, "街角咖啡", [1]), field(.amount, "24.00", [2])])
        let b = SemanticScene(category: "delivery", title: "取件", needsReview: false, evidence: [0], fields: [field(.code, "8-3021", [0])])
        guard case .accepted(let item) = try SemanticValidator.evaluate(SemanticResponse(scenes: [a,b]), document: document, blocks: document.blocks) else { return XCTFail() }
        XCTAssertEqual(item.category, .delivery); XCTAssertEqual(item.state, .needsReview)
    }
    @MainActor func testStoreSemanticFailureDoesNotRecordIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        var fail = true
        let store = SiftStore(repository: repository, recognize: { _ in self.doc(["请凭8-3021领取包裹"]) }, extract: { document in
            if fail { throw SemanticError.invalidOutput }
            return try SemanticValidator.evaluate(SemanticResponse(scenes: [SemanticScene(category: "delivery", title: "取件", needsReview: false, evidence: [0], fields: [self.field(.code, "8-3021", [0])])]), document: document, blocks: document.blocks)
        }, resumePendingJobs: false)
        await store.importImage(Data("fixture".utf8))
        XCTAssertEqual(store.jobs.count, 1); XCTAssertTrue(try repository.loadScanRecords().isEmpty)
        fail = false
        await store.retry(try XCTUnwrap(store.jobs.first))
        XCTAssertEqual(store.items.first?.code, "8-3021"); XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertEqual(try repository.loadScanRecords().first?.ruleVersion, SemanticPolicy.version)
    }
    @MainActor func testPolicyUpgradePreservesAcceptedHistoricalCardsWithoutInference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        let range = ScreenshotDateRange.recent(days: 7)
        let asset = LocalPhotoAsset(id: "historical", createdAt: range.end, modifiedAt: range.end)
        var old = InformationItem(category: .social, title: "历史聊天", rawText: "旧内容")
        old.photoAssetIdentifier = asset.id; old.note = "用户备注"
        try repository.save(old)
        try repository.finish(jobID: UUID(), record: ScanRecord(assetIdentifier: asset.id, assetModifiedAt: asset.modifiedAt, fingerprint: "old", ruleVersion: "old-rules", outcome: .accepted))
        let store = SiftStore(repository: repository, fetchAssets: { _ in [asset] }, loadImage: { _ in XCTFail("Unchanged historical card must not be loaded"); return Data() }, resumePendingJobs: false)
        let preview = try await store.previewScreenshots(in: range)
        XCTAssertEqual(preview.pending, 0)
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(store.items.first?.category, .social)
        XCTAssertEqual(store.items.first?.note, "用户备注")
    }
}
