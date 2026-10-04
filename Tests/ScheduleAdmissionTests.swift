import XCTest
@testable import Sift

final class ScheduleAdmissionTests: XCTestCase {
    private func doc(_ lines: [String]) -> OCRDocument {
        OCRDocument(rawText: lines.joined(separator: "\n"), blocks: lines.map { OCRBlock(text: $0, boundingBox: .zero, confidence: 0.98) }, recognitionLanguage: "zh-Hans", engineVersion: "synthetic-schedule-admission")
    }
    private func field(_ kind: FieldKind, _ value: String, _ sources: [Int]) -> SemanticField {
        SemanticField(kind: kind.rawValue, value: value, sources: sources)
    }
    private func scene(_ kind: ScheduleEvidence.Kind, _ sources: [Int], fields: [SemanticField] = []) -> SemanticScene {
        SemanticScene(category: "event", title: "模型生成的日程标题", needsReview: false, evidence: sources, fields: fields, scheduleEvidence: ScheduleEvidence(kind: kind, sources: sources))
    }
    private func evaluate(_ scenes: [SemanticScene], _ document: OCRDocument) throws -> ExtractionDecision {
        try SemanticValidator.evaluate(SemanticResponse(scenes: scenes), document: document, blocks: document.blocks)
    }
    private func accepted(_ scene: SemanticScene, _ document: OCRDocument) throws -> InformationItem {
        guard case .accepted(let item) = try evaluate([scene], document) else { throw SemanticError.invalidOutput }
        return item
    }
    private func assertIgnored(_ scene: SemanticScene, _ document: OCRDocument, file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .ignored = try evaluate([scene], document) else { return XCTFail("Unrelated scene survived admission: \(document.rawText)", file: file, line: line) }
    }

    func testForcedEventCannotAdmitQuestionsPlansReferencesOrDates() throws {
        let negatives = [
            "明天下午开会吗？", "明天上午十点开会吗", "准备下个月旅游", "计划下周去看房", "会议时间待定",
            "新闻：会议将于明天下午三点举行", "文章发布时间：2026年10月5日10:00", "订单创建时间：2026年10月5日10:00",
            "营业时间：每天9:00至17:00", "开放时间：周二上午九点", "火车时刻表 G123 10月5日08:20",
            "音乐节海报，10月5日举办，欢迎报名", "预约已取消", "牙科复诊预约已取消", "航班已退票",
            "普通聊天", "2026年10月5日10:00", "预约成功的操作教程", "面试邀请：明天上午十点有空吗？"
        ]
        for text in negatives {
            for kind in [ScheduleEvidence.Kind.confirmedReservation, .confirmedTravel, .explicitNotice] {
                try assertIgnored(scene(kind, [0], fields: [field(.eventName, text, [0])]), doc([text]))
            }
        }
    }

    func testDeclinedKindsAreSkippedEvenWhenModelReturnsValidDates() throws {
        let document = doc(["会议定在明天下午三点"])
        for kind in [ScheduleEvidence.Kind.reference, .tentative, .cancelled, .unrelated] {
            try assertIgnored(scene(kind, [0], fields: [field(.eventTime, "明天下午三点", [0])]), document)
        }
    }

    func testBookingHeaderCannotOverridePendingOrQuestionInAnotherBlock() throws {
        for status in ["预约状态：待确认", "牙科复诊时间待定", "明天牙科复诊有空吗？"] {
            try assertIgnored(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [1])]),
                              doc(["预约详情", "牙科复诊", "就诊时间：2026年10月5日09:30", status]))
        }
        let item = try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [1]), field(.eventTime, "2026年10月5日09:30", [2])]),
                                doc(["预约详情", "牙科复诊", "就诊时间：2026年10月5日09:30", "牙科复诊要带什么材料？"]))
        XCTAssertEqual(item.state, .pending)
        let booking = doc(["预约详情", "牙科复诊", "就诊时间：2026年10月5日09:30", "取消预约"])
        let booked = try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [1]), field(.eventTime, "2026年10月5日09:30", [2])]), booking)
        XCTAssertEqual(booked.state, .pending)
    }

    func testFieldWireFormatGeneratesValueBeforeCitationAndDecodesLegacyFixtures() throws {
        let field = SemanticField(kind: "eventName", value: "开会", sources: [2])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let wire = String(decoding: try encoder.encode(field), as: UTF8.self)
        XCTAssertFalse(wire.contains("\"sources\""))
        let literal = try XCTUnwrap(wire.range(of: "\"value\""))
        let citation = try XCTUnwrap(wire.range(of: "\"valueSources\""))
        XCTAssertLessThan(literal.lowerBound, citation.lowerBound)
        for key in ["sources", "valueSources"] {
            let json = "{\"kind\":\"eventName\",\"value\":\"开会\",\"\(key)\":[2]}"
            XCTAssertEqual(try JSONDecoder().decode(SemanticField.self, from: Data(json.utf8)).sources, [2])
        }
        let ambiguous = #"{"kind":"eventName","value":"开会","sources":[0],"valueSources":[2]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SemanticField.self, from: Data(ambiguous.utf8)))
    }

    func testHiddenConflictingISOAndRelativeChineseTimesAreNotSelected() throws {
        for times in [["2026-10-05 09:30", "2026-10-06 09:30"], ["明天上午十点", "明天下午三点"]] {
            let item = try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [0]), field(.eventTime, times[0], [1])]),
                                    doc(["牙科复诊预约已确认", "就诊时间：" + times[0], "就诊时间：" + times[1]]))
            XCTAssertEqual(item.state, .needsReview)
            XCTAssertFalse(item.fields.contains { $0.kind == .eventTime })
        }
    }

    func testFirstStageAllowsOrderedGroupsAndStandaloneUnrelated() throws {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(SemanticPolicy.relevanceSchema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let groups = try XCTUnwrap(properties["group"] as? [String: Any])
        let combinations = try XCTUnwrap(groups["enum"] as? [String])
        XCTAssertEqual(combinations.count, 16)
        XCTAssertTrue(combinations.contains("无关"))
        XCTAssertTrue(combinations.contains("领取、日程、消费、收藏"))
        XCTAssertFalse(combinations.contains("日程、领取"))
        XCTAssertFalse(combinations.contains("无关、日程"))
        XCTAssertFalse(combinations.contains("日程、日程"))
        let names = SemanticPolicy.literalValues(.eventName, texts: ["牙科复诊预约已确认；需要带什么材料？", "酒店预订成功", "西湖酒店"])
        XCTAssertTrue(names.contains("牙科复诊预约已确认"))
        XCTAssertTrue(names.contains("西湖酒店"))
        XCTAssertFalse(names.contains("需要带什么材料？"))
        XCTAssertFalse(names.contains("酒店预订成功"))
        XCTAssertTrue(ScheduleAdmission.locationLiterals("需要带什么材料？").isEmpty)
        XCTAssertTrue(ScheduleAdmission.locationLiterals("就诊时间：2026年10月5日09:30").isEmpty)
        XCTAssertEqual(ScheduleAdmission.locationLiterals("地点：县医院"), ["县医院"])
        XCTAssertEqual(ScheduleAdmission.locationLiterals("上海虹桥站"), ["上海虹桥站"])
    }

    func testRepeatedScheduleMissingOptionalFieldDoesNotBecomeMultipleEvents() throws {
        let document = doc(["皮肤科复诊", "10月5日上午10点", "县医院"])
        let complete = scene(.confirmedReservation, [0], fields: [field(.eventName, "皮肤科复诊", [0]), field(.eventTime, "10月5日上午10点", [1]), field(.location, "县医院", [2])])
        var partial = complete
        partial.fields.removeLast()
        partial.needsReview = true
        guard case .accepted(let item) = try evaluate([complete, partial], document) else { return XCTFail() }
        XCTAssertEqual(item.state, .pending)
        XCTAssertEqual(item.fields.first { $0.kind == .location }?.value, "县医院")
        partial.fields.removeAll { $0.kind == FieldKind.eventName.rawValue }
        guard case .accepted(let repeated) = try evaluate([complete, partial], document) else { return XCTFail() }
        XCTAssertEqual(repeated.state, .pending)
        let secondLocation = doc(["皮肤科复诊预约已确认", "10月5日上午10点", "县医院", "市医院"])
        var other = complete; other.fields[2] = field(.location, "市医院", [3])
        guard case .accepted(let ambiguous) = try evaluate([complete, other], secondLocation) else { return XCTFail() }
        XCTAssertEqual(ambiguous.state, .needsReview)
    }

    func testClearNoticeAndImplicitAppointmentSurviveWithoutFixedSuccessLabel() throws {
        let cases: [(ScheduleEvidence.Kind, [String], String, Int, String, Int)] = [
            (.explicitNotice, ["会议定在明天下午三点"], "会议", 0, "明天下午三点", 0),
            (.explicitNotice, ["明天上午十点开会"], "开会", 0, "明天上午十点", 0),
            (.confirmedReservation, ["皮肤科复诊", "10月5日上午10点", "县医院"], "皮肤科复诊", 0, "10月5日上午10点", 1),
            (.confirmedReservation, ["预约详情", "牙科复诊", "就诊时间：2026年10月5日09:30", "市口腔医院"], "牙科复诊", 1, "2026年10月5日09:30", 2),
            (.confirmedTravel, ["电子车票 已出票", "G123 高铁出行", "2026年10月5日08:20", "上海虹桥站"], "高铁出行", 1, "2026年10月5日08:20", 2),
            (.confirmedTravel, ["酒店预订成功", "西湖酒店", "入住时间：2026年10月5日15:00"], "西湖酒店", 1, "2026年10月5日15:00", 2)
        ]
        for entry in cases {
            let item = try accepted(scene(entry.0, [0], fields: [field(.eventName, entry.2, [entry.3]), field(.eventTime, entry.4, [entry.5])]), doc(entry.1))
            XCTAssertEqual(item.category, .event, entry.1.joined(separator: "\n"))
            XCTAssertEqual(item.state, .pending, entry.1.joined(separator: "\n"))
            XCTAssertEqual(item.fields.first(where: { $0.kind == .eventTime })?.value, entry.4)
        }
    }

    func testSameRowSeparateColumnsCanBindNoticeAndAbsoluteTime() throws {
        var document = doc(["会议通知", "2026年10月5日09:30"])
        document.blocks[0].boundingBox = CGRect(x: 0.05, y: 0.7, width: 0.3, height: 0.03)
        document.blocks[1].boundingBox = CGRect(x: 0.55, y: 0.7, width: 0.4, height: 0.03)
        let item = try accepted(scene(.explicitNotice, [0], fields: [field(.eventName, "会议", [0]), field(.eventTime, "2026年10月5日09:30", [1])]), document)
        XCTAssertEqual(item.state, .pending)
        XCTAssertEqual(item.fields.first { $0.kind == .eventTime }?.value, "2026年10月5日09:30")
    }

    func testConfirmedArrangementWithMissingOrConflictingFieldsRequiresReview() throws {
        let document = doc(["牙科复诊预约已确认", "就诊时间：2026年10月5日09:30", "就诊时间：2026年10月5日10:30"])
        let missing = try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [0])]), document)
        XCTAssertEqual(missing.state, .needsReview)
        XCTAssertFalse(missing.fields.contains { $0.kind == .eventTime })
        let conflict = try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [0]), field(.eventTime, "2026年10月5日09:30", [1]), field(.eventTime, "2026年10月5日10:30", [2])]), document)
        XCTAssertEqual(conflict.state, .needsReview)
        XCTAssertFalse(conflict.fields.contains { $0.kind == .eventTime })
        let hiddenConflict = try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [0]), field(.eventTime, "2026年10月5日09:30", [1])]), document)
        XCTAssertEqual(hiddenConflict.state, .needsReview)
        XCTAssertFalse(hiddenConflict.fields.contains { $0.kind == .eventTime })
        let noName = try accepted(scene(.confirmedReservation, [0]), document)
        XCTAssertEqual(noName.state, .needsReview)
    }

    func testCancellationCannotBeHiddenByCitingOnlyPositiveHeader() throws {
        let document = doc(["预约详情", "牙科复诊", "就诊时间：2026年10月5日09:30", "预约已取消"])
        try assertIgnored(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [1]), field(.eventTime, "2026年10月5日09:30", [2])]), document)
    }

    func testUnrelatedQuestionOrCancellationDoesNotCancelConfirmedSubject() throws {
        for other in ["需要带什么材料？", "理发预约已取消", "不必提前签到", "昨天的会议已取消"] {
            let document = doc(["会议定在明天下午三点", other])
            let item = try accepted(scene(.explicitNotice, [0], fields: [field(.eventName, "会议", [0]), field(.eventTime, "明天下午三点", [0])]), document)
            XCTAssertEqual(item.state, .pending, other)
        }
        let clinic = doc(["牙科复诊预约已确认，需要带什么材料？", "就诊时间：2026年10月5日09:30"])
        XCTAssertEqual(try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [0]), field(.eventTime, "2026年10月5日09:30", [1])]), clinic).state, .pending)
    }

    func testPublicPosterCannotUseNoticeHeadingAsProof() throws {
        let document = doc(["会议通知", "公开活动海报", "明天下午三点", "欢迎报名"])
        try assertIgnored(scene(.explicitNotice, [0], fields: [field(.eventName, "会议", [0]), field(.eventTime, "明天下午三点", [2])]), document)
    }

    func testDatesFromOtherSurfacesAndSeparateLabelsAreRemoved() throws {
        for label in ["订单创建时间", "消息时间", "发布时间", "营业时间", "开放时间"] {
            for lines in [["牙科复诊预约已确认", label + "：2026年10月5日09:30"], ["牙科复诊预约已确认", label, "2026年10月5日09:30"]] {
                let last = lines.count - 1
                let item = try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [0]), field(.eventTime, "2026年10月5日09:30", [last])]), doc(lines))
                XCTAssertEqual(item.state, .needsReview, label)
                XCTAssertFalse(item.fields.contains { $0.kind == .eventTime }, label)
            }
        }
    }

    func testChatTimestampDoesNotBecomeAppointmentTime() throws {
        let document = doc(["微信", "2026年10月5日09:30", "牙科复诊预约已确认"])
        let item = try accepted(scene(.confirmedReservation, [2], fields: [field(.eventName, "牙科复诊", [2]), field(.eventTime, "2026年10月5日09:30", [1])]), document)
        XCTAssertEqual(item.state, .needsReview)
        XCTAssertFalse(item.fields.contains { $0.kind == .eventTime })
    }

    func testTimeInDistantUnrelatedRegionIsNotAttachedToBooking() throws {
        var document = doc(["牙科复诊预约已确认", "2026年10月5日09:30"])
        document.blocks[0].boundingBox = CGRect(x: 0.05, y: 0.85, width: 0.4, height: 0.04)
        document.blocks[1].boundingBox = CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.04)
        let item = try accepted(scene(.confirmedReservation, [0], fields: [field(.eventName, "牙科复诊", [0]), field(.eventTime, "2026年10月5日09:30", [1])]), document)
        XCTAssertEqual(item.state, .needsReview)
        XCTAssertFalse(item.fields.contains { $0.kind == .eventTime })
    }

    func testLowOCRConfidenceRequiresReviewAfterAdmission() throws {
        var document = doc(["会议定在明天下午三点"])
        document.blocks[0].confidence = 0.5
        XCTAssertEqual(try accepted(scene(.explicitNotice, [0], fields: [field(.eventName, "会议", [0]), field(.eventTime, "明天下午三点", [0])]), document).state, .needsReview)
    }

    func testInvalidProofIsFailureRatherThanIgnored() throws {
        let document = doc(["会议定在明天下午三点"])
        for proof in [ScheduleEvidence(kind: .explicitNotice, sources: []), ScheduleEvidence(kind: .explicitNotice, sources: [9]), ScheduleEvidence(kind: .explicitNotice, sources: [0,0])] {
            var event = scene(.explicitNotice, [0]); event.scheduleEvidence = proof
            XCTAssertThrowsError(try evaluate([event], document))
        }
        var missing = scene(.explicitNotice, [0]); missing.scheduleEvidence = nil
        XCTAssertThrowsError(try evaluate([missing], document))
    }

    func testRejectedScheduleDoesNotDiscardOtherValidScene() throws {
        let document = doc(["明天下午开会吗？", "咖啡店支付成功", "实付：18.00"])
        let bad = scene(.explicitNotice, [0])
        let payment = SemanticScene(category: "payment", title: "咖啡消费", needsReview: false, evidence: [1,2], fields: [field(.merchant, "咖啡店", [1]), field(.amount, "18.00", [2])])
        guard case .accepted(let item) = try evaluate([bad, payment], document) else { return XCTFail() }
        XCTAssertEqual(item.category, .payment)
        XCTAssertEqual(item.amount, "18.00")
        XCTAssertEqual(item.state, .pending)
    }

    func testLongDocumentMergeKeepsIndependentScheduleProofs() throws {
        let valid = scene(.explicitNotice, [0], fields: [field(.eventName, "会议", [0]), field(.eventTime, "明天下午三点", [0])])
        let invalid = scene(.cancelled, [1])
        let merged = SemanticInput.merge([SemanticResponse(scenes: [invalid]), SemanticResponse(scenes: [valid])])
        XCTAssertEqual(merged.scenes.count, 2)
        guard case .accepted(let item) = try evaluate(merged.scenes, doc(["会议定在明天下午三点", "理发预约已取消"])) else { return XCTFail() }
        XCTAssertEqual(item.state, .pending)
    }

    func testSchemaRequiresProofOnlyForEventAndConstrainsKindsAndSources() throws {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(SemanticPolicy.schema(sourceIDs: [3,7]).utf8)) as? [String: Any])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let scenes = try XCTUnwrap(properties["scenes"] as? [String: Any])
        let items = try XCTUnwrap(scenes["items"] as? [String: Any])
        let variants = try XCTUnwrap(items["anyOf"] as? [[String: Any]])
        for variant in variants {
            let properties = try XCTUnwrap(variant["properties"] as? [String: Any])
            let category = try XCTUnwrap(properties["category"] as? [String: Any])
            let required = try XCTUnwrap(variant["required"] as? [String])
            XCTAssertEqual(required.contains("scheduleEvidence"), category["const"] as? String == "event")
            if category["const"] as? String == "event" {
                let proof = try XCTUnwrap(properties["scheduleEvidence"] as? [String: Any])
                let fields = try XCTUnwrap(proof["properties"] as? [String: Any])
                XCTAssertEqual((fields["kind"] as? [String: Any])?["enum"] as? [String], ScheduleEvidence.Kind.allCases.map(\.rawValue))
                let sources = try XCTUnwrap(fields["sources"] as? [String: Any])
                XCTAssertEqual((sources["items"] as? [String: Any])?["enum"] as? [Int], [3,7])
            }
        }
    }

    func testExtractionSchemaUsesFirstStageGroupsAndKeepsRequiredNullableScheduleSlots() throws {
        let json = SemanticPolicy.schema(sourceIDs: [0,1], texts: ["会议定在明天下午三点", "取件码：8-3021"], groups: [.schedules, .collectionCodes])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let array = try XCTUnwrap(properties["scenes"] as? [String: Any])
        let items = try XCTUnwrap(array["items"] as? [String: Any])
        let variants = try XCTUnwrap(items["anyOf"] as? [[String: Any]])
        var categories: Set<String> = []
        for variant in variants {
            let fields = try XCTUnwrap(variant["properties"] as? [String: Any])
            let category = try XCTUnwrap((fields["category"] as? [String: Any])?["const"] as? String)
            categories.insert(category)
            if category == "event" {
                let array = try XCTUnwrap(fields["fields"] as? [String: Any])
                let prefix = try XCTUnwrap(array["prefixItems"] as? [[String: Any]])
                XCTAssertEqual(array["minItems"] as? Int, 2)
                XCTAssertEqual(prefix.count, 2)
            }
        }
        XCTAssertEqual(categories, ["event", "delivery", "pickup"])
        XCTAssertEqual(SemanticPolicy.literalValues(.eventTime, texts: ["会议定在明天下午三点"]), ["明天下午三点"])
    }

    @MainActor func testUnrelatedEventDeletesTemporaryImageAndRecordsIgnoredInsteadOfReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        let document = doc(["明天下午开会吗？"])
        let response = scene(.explicitNotice, [0], fields: [field(.eventName, "开会", [0])])
        let store = SiftStore(repository: repository, recognize: { _ in document }, extract: { document in
            try SemanticValidator.evaluate(SemanticResponse(scenes: [response]), document: document, blocks: document.blocks)
        }, resumePendingJobs: false)
        await store.importImage(Data("schedule-admission-fixture".utf8))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertEqual(try repository.loadScanRecords().first?.outcome, .ignored)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).contains { $0.pathExtension == "image" })
    }

    @MainActor func testMalformedScheduleProofRemainsRetryableWithoutIgnoredRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        let document = doc(["会议定在明天下午三点"])
        var response = scene(.explicitNotice, [0], fields: [field(.eventName, "会议", [0]), field(.eventTime, "明天下午三点", [0])])
        response.scheduleEvidence = nil
        var malformed = true
        let store = SiftStore(repository: repository, recognize: { _ in document }, extract: { document in
            var output = response
            if !malformed { output.scheduleEvidence = ScheduleEvidence(kind: .explicitNotice, sources: [0]) }
            return try SemanticValidator.evaluate(SemanticResponse(scenes: [output]), document: document, blocks: document.blocks)
        }, resumePendingJobs: false)
        await store.importImage(Data("malformed-schedule-fixture".utf8))
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertTrue(try repository.loadScanRecords().isEmpty)
        malformed = false
        await store.retry(try XCTUnwrap(store.jobs.first))
        XCTAssertEqual(store.items.first?.category, .event)
        XCTAssertTrue(store.jobs.isEmpty)
    }
}
