import XCTest
@testable import Sift

final class ReprocessingTests: XCTestCase {
    private func document(_ lines: [String]) -> OCRDocument {
        .init(rawText: lines.joined(separator: "\n"), blocks: lines.enumerated().map { i, line in
            OCRBlock(text: line, boundingBox: CGRect(x: 0.1, y: 0.86 - Double(i) * 0.06, width: 0.6, height: 0.025), confidence: 0.98)
        }, recognitionLanguage: "zh-Hans", engineVersion: "test-layout")
    }
    private func pickup(_ lines: [String]) throws -> InformationItem {
        let layout = LayoutAnalysis(document: document(lines))
        let codes = layout.candidates.filter { $0.kind == "code" }
        let region = codes.first?.region ?? 0
        let decision = try GroundedExtraction.validate(.init(s: [.init(c: "pickup", r: region, n: -1, f: codes.map(\.id), e: codes.first?.evidence ?? [0], a: "none")], u: "content"), layout: layout)
        guard case .accepted(let item) = decision else { throw SemanticError.invalidOutput }
        return DisplayAdmission.apply(to: item)
    }

    func testStoreLabelsHeadersAndSignatures() throws {
        let samples: [([String], String)] = [
            (["肯德基", "取餐码：55"], "肯德基"),
            (["门店：瑞幸咖啡（科技园店）", "取餐码：9059"], "瑞幸咖啡（科技园店）"),
            (["餐厅", "麦当劳", "取餐码：A057"], "麦当劳"),
            (["【海底捞】您的餐食已备好，取餐码：C59"], "海底捞"),
            (["瑞幸咖啡", "（科技园店）", "取餐码：7284"], "瑞幸咖啡（科技园店）")
        ]
        for (lines, expected) in samples {
            let item = try pickup(lines)
            XCTAssertEqual(item.fields.first { $0.kind == .venue }?.value, expected, lines.joined(separator: " "))
            XCTAssertEqual(item.state, .pending)
            XCTAssertFalse(item.fields.first { $0.kind == .venue }?.sourceBlockIDs.isEmpty ?? true)
        }
    }

    func testMissingStorePlatformBodyAndAmbiguousOwnerStayOffHome() throws {
        for lines in [["取餐码：55"], ["美团", "取餐码：55"], ["您的餐食已备好", "取餐码：55"], ["好吧", "取餐码：55"], ["门店：肯德基", "门店：麦当劳", "取餐码：55"]] {
            let item = try pickup(lines)
            XCTAssertEqual(item.code, "55")
            XCTAssertTrue(item.needsReprocessing, lines.joined(separator: " "))
            XCTAssertNil(item.fields.first { $0.kind == .venue })
        }
    }

    func testStoreBelowCodeAndOCRVariantsDoNotTreatCodeLabelAsStore() throws {
        for lines in [["取餈码", "7284", "门店已接单", "浙江工业大学屏峰店＞"], ["取䬸码：55", "地址：杭州屏新路3号", "闪购 爷爷不泡茶（杭州铂悦城店）>"]] {
            let item = try pickup(lines)
            XCTAssertEqual(item.state, .pending)
            XCTAssertFalse(item.fields.first { $0.kind == .venue }?.value.hasPrefix("取") ?? true)
        }
    }

    func testStoreCannotCrossBusinessRegions() {
        var layout = LayoutAnalysis(document: document(["门店：肯德基", "取餐码：55", "门店：麦当劳", "取餐码：9059"]))
        layout.regions = [0, 0, 1, 1]
        layout.candidates = []; layout.buildCandidates()
        XCTAssertEqual(PickupStoreResolver.resolve(layout, region: 0, evidence: [1]).value, "肯德基")
        XCTAssertEqual(PickupStoreResolver.resolve(layout, region: 1, evidence: [3]).value, "麦当劳")
    }

    func testTwoExplicitOrdersAreBoundIndependentlyAndRepeatedFooterIsNotSplit() throws {
        let layout = LayoutAnalysis(document: document(["门店：肯德基", "取餐码：55", "门店：麦当劳", "取餐码：9059"]))
        let result = try XCTUnwrap(GroundedExtraction.direct(layout))
        guard case .accepted(let item) = result else { return XCTFail("Expected two grounded pickup scenes") }
        let scenes = try XCTUnwrap(item.recognizedScenes)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].fields.first { $0.kind == .venue }?.value, "肯德基")
        XCTAssertEqual(scenes[0].fields.first { $0.kind == .code }?.value, "55")
        XCTAssertEqual(scenes[1].fields.first { $0.kind == .venue }?.value, "麦当劳")
        XCTAssertEqual(scenes[1].fields.first { $0.kind == .code }?.value, "9059")
        XCTAssertEqual(DisplayAdmission.apply(to: item).state, .pending)
        let repeated = LayoutAnalysis(document: document(["门店：肯德基", "取餐码：55", "取餐号码：55"]))
        XCTAssertEqual(Set(repeated.regions), [0])
    }

    func testManualCorrectionClearsTypedConflictWithoutConfirmation() {
        var item = InformationItem(category: .pickup, title: "取餐通知", rawText: "取餐码：55")
        item.fields = [.init(kind: .code, value: "55", confidence: 0.99, sourceBlockIDs: [])]
        item.reprocessingReasons = [.init(kind: .uncertainOwnership, field: .venue, detail: "多个商家")]
        item.prepareForDisplay(); XCTAssertEqual(item.state, .needsReview)
        item.setUserEditedValue("肯德基", for: .venue)
        item.prepareForDisplay()
        XCTAssertEqual(item.state, .pending); XCTAssertEqual(item.displayApproval, .automatic)
        XCTAssertEqual(item.reprocessingReasons, [])
    }

    func testAdvisoriesAndOptionalFieldsDoNotGateCompleteCards() {
        var item = InformationItem(category: .delivery, title: "取件通知", rawText: "取件码：9059")
        item.fields = [.init(kind: .code, value: "9059", confidence: 0.98, sourceBlockIDs: [])]
        item.reviewReasons = ["由模型判断", "截图包含多个独立事项"]
        item.reprocessingReasons = [.init(kind: .conflictingRequiredField, field: .deadline, detail: "截止时间冲突")]
        item.prepareForDisplay(); XCTAssertEqual(item.state, .pending)
        item.state = .completed; item.fields = []; item.prepareForDisplay(); XCTAssertEqual(item.state, .completed)
        item.state = .archived; item.prepareForDisplay(); XCTAssertEqual(item.state, .archived)
    }

    func testComplementaryTextAndResourcesAreNotConflictingAnswers() {
        for kind in [FieldKind.excerpt, .issueSteps, .url, .route] {
            var item = InformationItem(category: .technical, title: "设备设置操作指南", rawText: "原文")
            item.fields = [
                .init(kind: kind, value: "第一段原文", confidence: 0.98, sourceBlockIDs: []),
                .init(kind: kind, value: "第二段原文", confidence: 0.4, sourceBlockIDs: [])
            ]
            item.reviewReasons = ["部分原文识别不清，请核对"]
            item.reprocessingReasons = [
                .init(kind: .conflictingRequiredField, field: kind, detail: "旧版误报"),
                .init(kind: .unreadableRequiredField, field: kind, detail: "旧版误报")
            ]
            item.prepareForDisplay()
            XCTAssertEqual(item.state, .pending, kind.rawValue)
            XCTAssertEqual(item.reprocessingReasons, [])
            XCTAssertEqual(item.fields.count, 2)
        }
    }

    func testRealScalarConflictsAndUnclearNumbersRemainBlocked() {
        for (category, kind, first, second) in [(Category.delivery, FieldKind.code, "9059", "55"), (.payment, .amount, "37.66", "3400.00"), (.event, .eventTime, "2026年10月8日09:30", "2026年10月8日10:30")] {
            var item = InformationItem(category: category, title: "明确主体", rawText: "原文")
            item.fields = [
                .init(kind: kind, value: first, confidence: 0.98, sourceBlockIDs: []),
                .init(kind: kind, value: second, confidence: 0.98, sourceBlockIDs: []),
                .init(kind: .merchant, value: "街角咖啡", confidence: 0.98, sourceBlockIDs: []),
                .init(kind: .eventName, value: "明确会议", confidence: 0.98, sourceBlockIDs: [])
            ]
            item.prepareForDisplay()
            XCTAssertTrue(item.needsReprocessing)
            XCTAssertTrue(item.reprocessingReasons?.contains { $0.field == kind && $0.kind == .conflictingRequiredField } ?? false)
        }
        var unclear = InformationItem(category: .delivery, title: "领取通知", rawText: "9059")
        unclear.fields = [.init(kind: .code, value: "9059", confidence: 0.3, sourceBlockIDs: [])]
        unclear.prepareForDisplay()
        XCTAssertTrue(unclear.needsReprocessing)
        XCTAssertEqual(unclear.reprocessingReasons?.first?.kind, .unreadableRequiredField)
    }

    func testGroundedStoreNameAtMediumOCRConfidenceIsUsableButUnclearCodeIsNot() {
        var item = InformationItem(category: .pickup, title: "爷爷不泡茶（杭州铂悦城店）", rawText: "取餐码55")
        item.fields = [
            .init(kind: .venue, value: item.title, confidence: 0.5, sourceBlockIDs: []),
            .init(kind: .code, value: "55", confidence: 1, sourceBlockIDs: [])
        ]
        item.reprocessingReasons = [.init(kind: .unreadableRequiredField, field: .venue, detail: "旧版门槛过高")]
        item.prepareForDisplay(); XCTAssertEqual(item.state, .pending)
        item.fields[0].confidence = 0.3
        item.prepareForDisplay(); XCTAssertEqual(item.state, .needsReview)
        item.fields[0].confidence = 0.5; item.fields[1].confidence = 0.5
        item.prepareForDisplay(); XCTAssertTrue(item.reprocessingReasons?.contains { $0.field == .code && $0.kind == .unreadableRequiredField } ?? false)
    }

    @MainActor func testLegacyExcerptConflictRecoversOnRestartWithoutRecognition() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LocalRepository(directory: dir)
        var item = InformationItem(category: .learning, title: "设备设置指南", rawText: "第一段\n第二段")
        item.state = .needsReview
        item.imageName = "retained.image"
        item.fields = [
            .init(kind: .excerpt, value: "第一段", confidence: 0.98, sourceBlockIDs: []),
            .init(kind: .excerpt, value: "第二段", confidence: 0.4, sourceBlockIDs: [], isUserEdited: true)
        ]
        let stale = ReprocessingReason(kind: .conflictingRequiredField, field: .excerpt, detail: "文字摘录存在冲突")
        item.reprocessingReasons = [stale]
        item.recognizedScenes = [
            .init(category: .learning, title: item.title, fields: item.fields, contentNature: "参考收藏", reviewReasons: [], reprocessingReasons: [stale]),
            .init(category: .technical, title: "第二份指南", fields: item.fields, contentNature: "参考收藏", reviewReasons: [], reprocessingReasons: [stale])
        ]
        try Data("image".utf8).write(to: dir.appendingPathComponent(item.imageName))
        try repository.save(item)
        for _ in 0..<2 {
            let store = SiftStore(repository: repository, recognize: { _ in XCTFail("Must not rerun OCR"); return self.document([]) }, extract: { _ in XCTFail("Must not invoke model"); return .ignored }, resumePendingJobs: false)
            XCTAssertEqual(store.displayableItems.count, 1)
            XCTAssertTrue(store.reprocessingEntries.isEmpty)
            XCTAssertEqual(store.items.first?.fields, item.fields)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(item.imageName).path))
        }
    }

    func testIncompleteSecondarySceneAndLowClarityStayInReprocessing() {
        var item = InformationItem(category: .delivery, title: "领取", rawText: "截图")
        item.fields = [.init(kind: .code, value: "9059", confidence: 0.98, sourceBlockIDs: [])]
        item.recognizedScenes = [
            .init(category: .delivery, title: "领取", fields: item.fields, contentNature: "实际记录", reviewReasons: []),
            .init(category: .pickup, title: "取餐通知", fields: [.init(kind: .code, value: "55", confidence: 0.98, sourceBlockIDs: [])], contentNature: "实际记录", reviewReasons: [])
        ]
        item.prepareForDisplay(); XCTAssertEqual(item.state, .needsReview)
        item.recognizedScenes?[1].fields.append(.init(kind: .venue, value: "麦当劳", confidence: 1, sourceBlockIDs: [], isUserEdited: true))
        item.prepareForDisplay(); XCTAssertEqual(item.state, .pending)
        item.fields[0].confidence = 0.4; item.prepareForDisplay(); XCTAssertEqual(item.state, .needsReview)
    }

    @MainActor func testStoreRetriesPreserveImageAndRestoreHomeAndManualSaveClearsFailedJob() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LocalRepository(directory: dir)
        var fail = false
        var complete = false
        let store = SiftStore(repository: repository, recognize: { _ in self.document(["取餐码：55"]) }, extract: { _ in
            if fail { throw SemanticError.invalidOutput }
            return .accepted(try self.pickup(complete ? ["肯德基", "取餐码：55"] : ["取餐码：55"]))
        }, resumePendingJobs: false)
        await store.importImage(Data("saved-image".utf8))
        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(store.displayableItems.isEmpty); XCTAssertEqual(store.reprocessingEntries.count, 1)
        fail = true; await store.retry(item)
        XCTAssertEqual(store.reprocessingEntries.count, 1); XCTAssertEqual(store.jobs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(item.imageName).path))
        fail = false; complete = true; await store.retry(item)
        XCTAssertEqual(store.displayableItems.count, 1); XCTAssertTrue(store.reprocessingEntries.isEmpty)
        XCTAssertEqual(store.items.first?.id, item.id)
        fail = true; await store.retry(store.items[0])
        XCTAssertTrue(store.displayableItems.isEmpty)
        var edited = store.items[0]; edited.setUserEditedValue("麦当劳", for: .venue)
        try store.save(edited)
        XCTAssertTrue(store.jobs.isEmpty); XCTAssertEqual(store.displayableItems.count, 1)
        let restored = SiftStore(repository: repository, resumePendingJobs: false)
        XCTAssertEqual(restored.displayableItems.count, 1)
        XCTAssertEqual(restored.items.first?.imageName, item.imageName)
    }

    @MainActor func testRetryIgnoredKeepsPreviousDataAndFailedTaskOffHome() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LocalRepository(directory: dir)
        var ignore = false
        let store = SiftStore(repository: repository, recognize: { _ in self.document(["取餐码：55"]) }, extract: { _ in
            ignore ? .ignored : .accepted(try self.pickup(["肯德基", "取餐码：55"]))
        }, resumePendingJobs: false)
        await store.importImage(Data("saved-image".utf8))
        let original = try XCTUnwrap(store.items.first)
        ignore = true; await store.retry(original)
        XCTAssertEqual(store.items.first?.id, original.id)
        XCTAssertEqual(store.items.first?.code, "55")
        XCTAssertTrue(store.displayableItems.isEmpty)
        XCTAssertEqual(store.jobs.first?.state, .failed)
        XCTAssertEqual(store.reprocessingEntries.count, 1)
        let restored = SiftStore(repository: repository, resumePendingJobs: false)
        XCTAssertTrue(restored.displayableItems.isEmpty)
        XCTAssertEqual(restored.reprocessingEntries.count, 1)
    }

    func testLegacyOptionalPropertiesDecodeWithoutApprovalGate() throws {
        var item = InformationItem(category: .delivery, title: "领取", rawText: "取件码：9059")
        item.code = "9059"
        let data = try JSONEncoder().encode(item)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "reprocessingReasons"); payload.removeValue(forKey: "displayApproval")
        var restored = try JSONDecoder().decode(InformationItem.self, from: JSONSerialization.data(withJSONObject: payload))
        restored.prepareForDisplay(); XCTAssertEqual(restored.state, .pending)
        restored.state = .archived; restored.code = ""; restored.fields = []
        restored.prepareForDisplay(); XCTAssertEqual(restored.state, .archived)
    }

    @MainActor func testMarkingIncompleteCardCompleteDoesNotBypassFieldCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SiftStore(repository: try LocalRepository(directory: dir), resumePendingJobs: false)
        var item = try pickup(["取餐码：55"])
        try store.save(item)
        item.state = .completed; try store.save(item)
        XCTAssertEqual(store.items.first?.state, .needsReview)
        XCTAssertTrue(store.displayableItems.isEmpty)
        item.setUserEditedValue("肯德基", for: .venue); try store.save(item)
        XCTAssertEqual(store.items.first?.state, .completed)
    }
}
