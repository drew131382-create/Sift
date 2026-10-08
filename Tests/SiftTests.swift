import XCTest
@testable import Sift

private typealias SiftContentCategory = Sift.Category

final class SiftTests: XCTestCase {
    func testDeliveryCodeDoesNotUsePhoneNumber() {
        let item = RuleExtractor().extract("菜鸟驿站\n手机号 13812345678\n取件码：3-7-211")
        XCTAssertEqual(item.category, .delivery)
        XCTAssertEqual(item.code, "3-7-211")
    }
    func testPaymentUsesActualAmount() {
        let item = RuleExtractor().extract("原价 100.00\n优惠 20.00\n实付金额：￥80.00")
        XCTAssertEqual(item.amount, "80.00")
    }
    func testUnknownDoesNotInventTimeOrCode() {
        let item = RuleExtractor().extract("明天或许去看看展览\n订单号123456")
        XCTAssertEqual(item.category, .other)
        XCTAssertEqual(item.code, "")
        XCTAssertNil(item.reminderAt)
    }
    func testPersistenceRoundTripAndUpdate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try LocalRepository(directory: url)
        var item = RuleExtractor().extract("取餐号 A057")
        try repository.save(item)
        item.note = "用户修正"
        try repository.save(item)
        let loaded = try repository.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.note, "用户修正")
        XCTAssertEqual(loaded.first?.code, "A057")
    }

    func testExpandedCategoryAndIntentExtraction() {
        let item = RuleExtractor().extract("购物车里的商品，之后想买，价格对比参考")
        XCTAssertEqual(item.category, .shopping)
        XCTAssertTrue(item.intents.contains(.purchaseCandidate))
        XCTAssertTrue(item.intents.contains(.reviewLater))
        XCTAssertEqual(item.state, .pending)
        XCTAssertTrue(item.matchedKeywords.contains("购物车"))
    }

    func testFieldKeepsOCRSourceBlock() {
        let item = RuleExtractor().extract("菜鸟驿站\n取件码：A-057")
        XCTAssertEqual(item.code, "A-057")
        XCTAssertEqual(item.fields.first?.kind, .code)
        XCTAssertEqual(item.fields.first?.value, "A-057")
        XCTAssertFalse(item.fields.first?.sourceBlockIDs.isEmpty ?? true)
    }

    func testExplicitDateAndURLAreExtractedWithoutRelativeInference() {
        let item = RuleExtractor().extract("活动时间：2026年10月2日 19:30\n详情 https://example.com/event")
        XCTAssertEqual(item.category, .event)
        XCTAssertTrue(item.fields.contains { $0.kind == .date && $0.value.contains("2026") })
        XCTAssertTrue(item.fields.contains { $0.kind == .time && $0.value == "19:30" })
        XCTAssertTrue(item.fields.contains { $0.kind == .url && $0.value == "https://example.com/event" })
        XCTAssertNil(item.reminderAt)
    }

    func testLegacyPayloadCanBeDecoded() throws {
        let json = """
        {
          "category": "快递",
          "title": "菜鸟驿站",
          "rawText": "取件码：A057",
          "code": "A057",
          "state": "待确认"
        }
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(InformationItem.self, from: json)
        XCTAssertEqual(item.category, .delivery)
        XCTAssertEqual(item.state, .needsReview)
        XCTAssertEqual(item.code, "A057")
        XCTAssertEqual(item.fields.first?.kind, .code)
        XCTAssertEqual(item.category.cardFields.map { $0.displayValue(for: item) }, ["A057", "待识别"])
    }

    func testAdditionalFieldsKeepExplicitSources() {
        let item = RuleExtractor().extract("活动时间：2026年10月2日 19:30\n地点：上海展览中心\n商户：Sift Cafe\n商品：手冲咖啡\n地址：上海市静安区南京西路\n联系方式：021-12345678")
        XCTAssertTrue(item.fields.contains { $0.kind == .location && $0.value == "上海展览中心" })
        XCTAssertTrue(item.fields.contains { $0.kind == .merchant && $0.value == "Sift Cafe" })
        XCTAssertTrue(item.fields.contains { $0.kind == .product && $0.value == "手冲咖啡" })
        XCTAssertTrue(item.fields.contains { $0.kind == .address && $0.value == "上海市静安区南京西路" })
        XCTAssertTrue(item.fields.contains { $0.kind == .contact && $0.value == "021-12345678" })
        XCTAssertTrue(item.fields.allSatisfy { !$0.sourceBlockIDs.isEmpty })
    }

    func testProcessingJobRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try LocalRepository(directory: url)
        var job = ProcessingJob(imageName: "test.image", fingerprint: "abc")
        job.state = .failed
        job.errorMessage = "测试错误"
        try repository.save(job: job)
        let loaded = try repository.loadJobs()
        XCTAssertEqual(loaded.first?.state, .failed)
        XCTAssertEqual(loaded.first?.errorMessage, "测试错误")
    }

    func testEveryCategoryHasTwoStableCardFields() {
        let expected: [SiftContentCategory: [String]] = [
            .delivery: ["取货码", "快递驿站"],
            .pickup: ["餐厅 / 门店", "取餐号码"],
            .payment: ["付款商户", "实付金额"],
            .event: ["活动名称", "活动时间"],
            .shopping: ["商品名称", "实付金额"],
            .place: ["地点名称", "地址 / 路线"],
            .learning: ["资料标题", "课程 / 主题"],
            .health: ["检查 / 药品项目", "就诊 / 检查日期"],
            .social: ["聊天内容", "消息摘录"],
            .technical: ["操作对象", "问题 / 操作步骤"],
            .documentation: ["凭证类型", "凭证编号 / 日期"],
            .inspiration: ["内容标题", "文字摘录"],
            .other: ["截图标题", "文字摘录"]
        ]

        XCTAssertEqual(expected.count, SiftContentCategory.allCases.count)
        for category in SiftContentCategory.allCases {
            XCTAssertEqual(category.cardFields.map(\.label), expected[category])
            XCTAssertEqual(category.cardFields.count, 2)
            let empty = InformationItem(category: category, title: "", rawText: "")
            XCTAssertEqual(category.cardFields.map { $0.displayValue(for: empty) }, ["待识别", "待识别"])
        }
    }

    func testCategorySpecificFieldsAreExtractedAndDisplayed() {
        let samples: [(String, SiftContentCategory, [String])] = [
            ("快递：顺丰\n取件码：A-123\n驿站名称：静安驿站", .delivery, ["A-123", "静安驿站"]),
            ("取餐号：B057\n餐厅：麦当劳", .pickup, ["麦当劳", "B057"]),
            ("商户：咖啡店\n支付成功\n实付金额：￥24.00", .payment, ["咖啡店", "24.00"]),
            ("活动名称：独立音乐节\n活动时间：2026年10月2日 19:30", .event, ["独立音乐节", "2026年10月2日 · 19:30"]),
            ("商品名称：咖啡机\n商品价格：199.00", .shopping, ["咖啡机", "待识别"]),
            ("地点名称：西湖\n地址：杭州市西湖区", .place, ["西湖", "杭州市西湖区"]),
            ("资料标题：线性代数笔记\n课程主题：矩阵", .learning, ["线性代数笔记", "矩阵"]),
            ("检查项目：血常规\n日期：2026年10月2日", .health, ["血常规", "2026年10月2日"]),
            ("群聊名称：旅行计划\n消息：周六出发", .social, ["旅行计划", "消息：周六出发"]),
            ("应用名称：设置\n报错：无法连接", .technical, ["设置", "无法连接"]),
            ("凭证类型：发票\n发票号码：INV-100", .documentation, ["发票", "INV-100"]),
            ("收藏标题：海边日落\n海边像橙色画布", .inspiration, ["海边日落", "海边像橙色画布"]),
            ("截图标题：会议备忘\n这段文字留作参考", .other, ["会议备忘", "这段文字留作参考"])
        ]

        for (text, category, values) in samples {
            let item = RuleExtractor().extract(text)
            XCTAssertEqual(item.category, category, "\(text)")
            XCTAssertEqual(category.cardFields.map { $0.displayValue(for: item) }, values, "\(text)")
            XCTAssertTrue(item.fields.allSatisfy { !$0.sourceBlockIDs.isEmpty }, "\(text)")
        }
    }

    func testPriceDoesNotReuseOriginalPriceOrPaymentAmount() {
        let item = RuleExtractor().extract("商品名称：咖啡机\n原价：299.00")
        XCTAssertEqual(item.category, .shopping)
        XCTAssertNil(item.fields.first(where: { $0.kind == .price }))
        XCTAssertNil(item.fields.first(where: { $0.kind == .amount }))
        XCTAssertEqual(item.category.cardFields[1].displayValue(for: item), "待识别")
    }

    func testUserEditedCardFieldsPersistAndOverrideRecognition() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try LocalRepository(directory: url)
        var original = RuleExtractor().extract("取餐号：A057\n餐厅：旧门店")
        try repository.save(original)

        let venueSlot = original.category.cardFields[0]
        original.setCardValue("用户更正的门店", for: venueSlot)
        try repository.save(original)

        var refreshed = RuleExtractor().extract("取餐号：A057\n餐厅：新识别门店")
        refreshed.id = original.id
        refreshed.preserveUserEdits(from: original)
        try repository.save(refreshed)

        let saved = try XCTUnwrap(repository.load().first)
        XCTAssertEqual(saved.category.cardFields[0].displayValue(for: saved), "用户更正的门店")
        XCTAssertTrue(saved.fields.first(where: { $0.kind == .venue })?.isUserEdited == true)
        XCTAssertEqual(saved.code, "A057")
    }

    func testClearedUserValueStaysMissingInsteadOfFallingBack() {
        var item = RuleExtractor().extract("地址：杭州市西湖区\n路线：湖滨路步行")
        let addressSlot = item.category.cardFields.first(where: { $0.label == "地址 / 路线" })!
        item.setCardValue("", for: addressSlot)
        XCTAssertEqual(addressSlot.displayValue(for: item), "待识别")
    }
}
