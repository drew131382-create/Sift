import XCTest
import MLXLMCommon
@testable import Sift

final class GroundedExtractionTests: XCTestCase {
    func doc(_ lines: [String]) -> OCRDocument {
        OCRDocument(rawText: lines.joined(separator: "\n"), blocks: lines.enumerated().map { i, line in OCRBlock(text: line, boundingBox: CGRect(x: 0.1, y: 0.85 - Double(i) * 0.06, width: 0.6, height: 0.025), confidence: 0.95) }, recognitionLanguage: "zh-Hans", engineVersion: "synthetic-layout")
    }
    func testLegacyImageDataRemainsTransient() throws {
        var document = doc(["取餐码：55", "街角茶店"])
        document.sourceImageData = Data([1, 2, 3, 4])
        let encoded = try JSONEncoder().encode(document)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sourceImageData"))
        let restored = try JSONDecoder().decode(OCRDocument.self, from: encoded)
        XCTAssertNil(restored.sourceImageData)
        XCTAssertEqual(restored, document.textOnly)
        let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document: document)))
        XCTAssertNil(item.ocrDocument?.sourceImageData)
        XCTAssertEqual(item.code, "55")
    }
    func testComplexSLMPathDoesNotRequireOriginalImage() async throws {
        let engine = LocalModelEngine(directory:nil,modelOnly:true)
        do {
            _ = try await engine.evaluate(document:doc(["城市博物馆","地址：人民路20号"]))
            XCTFail("A missing model or unsupported simulator must fail")
        } catch SemanticError.unsupportedDevice { }
        catch SemanticError.modelMissing { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func accepted(_ decision: ExtractionDecision?) throws -> InformationItem {
        guard case .accepted(let item) = decision else { throw SemanticError.invalidOutput }
        return item
    }
    func testSplitCodeAndReceiptLabelsAreGrounded() throws {
        let pickup = try accepted(GroundedExtraction.direct(LayoutAnalysis(document: doc(["街角茶店", "取餐码", "55"]))))
        XCTAssertEqual(pickup.category, .pickup); XCTAssertEqual(pickup.code, "55")
        XCTAssertEqual(pickup.fields.first { $0.kind == .code }?.sourceBlockIDs.count, 2)
        let receipt = try accepted(GroundedExtraction.direct(LayoutAnalysis(document: doc(["商户：街角咖啡", "实际支付", "¥37.66", "优惠：5.00"]))))
        XCTAssertEqual(receipt.amount, "37.66"); XCTAssertEqual(receipt.title,"街角咖啡")
    }
    func testTransferSuccessAndCurrency() throws {
        let document = OCRDocument(rawText: "转账成功\n¥3400.00\n收款方\n合欢公寓", blocks: [
            OCRBlock(text: "转账成功", boundingBox: CGRect(x: 0.35,y:0.7,width:0.3,height:0.05), confidence: 0.95),
            OCRBlock(text: "¥3400.00", boundingBox: CGRect(x:0.25,y:0.45,width:0.5,height:0.1), confidence:0.95),
            OCRBlock(text: "收款方", boundingBox: CGRect(x:0.1,y:0.28,width:0.2,height:0.02), confidence:0.95),
            OCRBlock(text: "合欢公寓", boundingBox: CGRect(x:0.55,y:0.28,width:0.3,height:0.02), confidence:0.95)
        ], recognitionLanguage: "zh-Hans", engineVersion: "synthetic-layout")
        let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document: document)))
        XCTAssertEqual(item.amount, "3400.00"); XCTAssertEqual(item.title, "合欢公寓")
        XCTAssertEqual(item.fields.first { $0.kind == .amount }?.displayValue, "¥3400.00")
    }
    func testAmbiguousNumbersDoNotTakeShortcut() throws {
        var ambiguous = doc(["取餐码", "55", "56"])
        ambiguous.blocks[2].boundingBox = CGRect(x: 0.72, y: 0.79, width: 0.2, height: 0.025)
        XCTAssertNil(try GroundedExtraction.direct(LayoutAnalysis(document: ambiguous)))
        for text in ["订单号：9059", "原价：100 优惠：20 余额：80", "明天下午开会吗", "准备下个月旅游", "公开活动时间10月5日15:00", "已订阅开场提醒"] {
            XCTAssertNil(try GroundedExtraction.direct(LayoutAnalysis(document: doc([text]))), text)
        }
    }
    func testModelCannotInventIDsOrCreateEmptyCards() throws {
        let layout = LayoutAnalysis(document: doc(["取餐码：9059", "街角茶店"]))
        let broken = SemanticSelection(s: [.init(c:"pickup",r:0,n:-1,f:[999],e:[0],a:"none")],u:"content")
        XCTAssertThrowsError(try GroundedExtraction.validate(broken, layout: layout))
        let empty = SemanticSelection(s:[.init(c:"pickup",r:0,n:-1,f:[],e:[0],a:"none")],u:"content")
        XCTAssertThrowsError(try GroundedExtraction.validate(empty, layout:layout))
        XCTAssertThrowsError(try GroundedExtraction.validate(.init(s:[],u:"uncertain"), layout:layout))
    }
    func testUnsupportedScheduleRemovedWithoutRemovingOtherScene() throws {
        let layout = LayoutAnalysis(document: doc(["会议定在明天下午三点", "商品原价199", "取餐码：9059"]))
        let code = try XCTUnwrap(layout.candidates.first { $0.kind == "code" })
        let response = SemanticSelection(s:[.init(c:"event",r:0,n:-1,f:[],e:[1],a:"confirmed"), .init(c:"pickup",r:0,n:-1,f:[code.id],e:[2],a:"none")],u:"content")
        XCTAssertEqual(try accepted(GroundedExtraction.validate(response,layout:layout)).category,.pickup)
    }
    func testQuotesRetainUnitsAndNeverBecomePaid() throws {
        let layout = LayoutAnalysis(document: doc(["钛7EV", "经销商报价：19.98-23.98万"]))
        let subject = try XCTUnwrap(layout.candidates.first { $0.kind == "subject" })
        let price = try XCTUnwrap(layout.candidates.first { $0.kind == "price" })
        let item = try accepted(GroundedExtraction.validate(.init(s:[.init(c:"inspiration",r:0,n:subject.id,f:[price.id],e:[0,1],a:"reference")],u:"content"), layout:layout))
        XCTAssertEqual(item.category.group,.collections); XCTAssertEqual(item.amount, "")
        XCTAssertEqual(item.fields.first { $0.kind == .price }?.displayValue,"19.98-23.98万")
    }
    func testCancelledStateVersusButton() throws {
        let layout = LayoutAnalysis(document: doc(["预约详情", "牙科复诊", "2026年10月3日09:30", "取消订单"]))
        XCTAssertNotNil(try GroundedExtraction.direct(layout))
        XCTAssertNil(try GroundedExtraction.direct(LayoutAnalysis(document:doc(["您的预约已取消", "2026年10月3日09:30"])) ))
    }
    func testHistoricalFieldsAndItemsDecodeWithoutMetadata() throws {
        let json = "{\"category\":\"shopping\",\"title\":\"旧订单\",\"fields\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"kind\":\"amount\",\"value\":\"24.00\",\"confidence\":1,\"sourceBlockIDs\":[],\"isUserEdited\":true}]}"
        let old = try JSONDecoder().decode(InformationItem.self, from:Data(json.utf8))
        XCTAssertNil(old.contentNature); XCTAssertNil(old.recognizedScenes); XCTAssertNil(old.fields[0].unit)
        XCTAssertEqual(old.fields[0].displayValue,"24.00")
        XCTAssertNoThrow(try JSONDecoder().decode(InformationItem.self, from:JSONEncoder().encode(old)))
    }
    func testDirectPathDoesNotRequireModelOnSimulator() async throws {
        let engine = LocalModelEngine(directory:nil)
        let item = try accepted(try await engine.evaluate(document:doc(["取餐码：9059", "街角茶店"])))
        XCTAssertEqual(item.code,"9059"); await engine.release()
    }
    func testDateClockAssociationAndUIExclusions() throws {
        let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["预约详情", "牙科复诊", "日期：2026年10月3日", "时间：09:30", "取消订单"]))))
        XCTAssertEqual(item.fields.first { $0.kind == .eventTime }?.value,"2026年10月3日\n09:30")
        XCTAssertEqual(item.state,.pending)
        let detail = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["预约详情","牙科复诊","2026年10月3日09:30","取消订单"]))))
        XCTAssertEqual(detail.title,"牙科复诊")
        XCTAssertEqual(detail.fields.first { $0.kind == .eventTime }?.value,"2026年10月3日09:30")
        for raw in ["2026年2月30日09:30","10月32日09:30","10月3日25:00"] { XCTAssertFalse(GroundedExtraction.validTime(raw)) }
        let layout = LayoutAnalysis(document:doc(["09:574", "订单创建时间：2026年10月3日09:30", "微信", "17:53"]))
        XCTAssertTrue(layout.candidates.filter { $0.kind == "eventTime" }.isEmpty)
    }
    func testQuestionAndNegativePaymentDoNotCreateCandidates() throws {
        for raw in ["未支付金额：37.66", "退款支付金额：37.66", "支付成功了吗", "取餐码55吗？"] {
            let layout = LayoutAnalysis(document:doc([raw]))
            XCTAssertTrue(layout.candidates.filter { ["amount","code"].contains($0.kind) }.isEmpty,raw)
            XCTAssertNil(try GroundedExtraction.direct(layout),raw)
        }
        XCTAssertTrue(LayoutAnalysis.paymentEvidence("原价100，实付80，优惠20"))
        let negative = LayoutAnalysis(document:doc(["微信", "还没有支付金额37.66"]))
        let subject = try XCTUnwrap(negative.candidates.first { $0.kind == "subject" && $0.value.contains("还没有") })
        let decision = try GroundedExtraction.validate(.init(s:[.init(c:"payment",r:0,n:subject.id,f:[],e:[1],a:"none")],u:"content"),layout:negative)
        if case .accepted = decision { XCTFail("否定付款不能建待确认卡") }
        for (currency,amount) in [("USD","37.66"),("€","20.00"),("HK$","3400.00")] {
            let receipt = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["付款凭证", "实付" + currency + amount]))))
            XCTAssertEqual(receipt.fields.first { $0.kind == .amount }?.displayValue,currency + amount)
        }
        XCTAssertNil(try GroundedExtraction.direct(LayoutAnalysis(document:doc(["支付成功教程", "实付37.66", "例如取餐码9059"])) ))
    }
    func testDuplicateSelectionIDsNormalizeButUnknownIDsFail() throws {
        let layout = LayoutAnalysis(document:doc(["街角茶店", "取餐码55"]))
        let field = try XCTUnwrap(SelectionInput.fieldTable(layout).firstIndex { $0.kind == "code" })
        let json = "{\"category\":\"领取\",\"subject\":0,\"fields\":[\(field),\(field)],\"evidence\":[1,1],\"arrangement\":\"无\"}"
        let item = try accepted(GroundedExtraction.validate(SelectionPolicy.decode(json,layout:layout),layout:layout))
        XCTAssertEqual(item.code,"55")
        XCTAssertThrowsError(try SelectionPolicy.decode(json.replacingOccurrences(of:"[\(field),\(field)]",with:"[999]"),layout:layout))
    }
    func testIndependentIdenticalOrdersRemainSeparate() throws {
        let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["交易成功", "甲书店", "实付4.7", "交易成功", "甲书店", "实付4.7"]))))
        XCTAssertEqual(item.recognizedScenes?.count,2)
        XCTAssertEqual(item.state,.needsReview)
        XCTAssertEqual(try accepted(GroundedExtraction.merge([.accepted(item),.accepted(item)])).recognizedScenes?.count,2)
    }
    func testSideBySideOrderBoundaries() throws {
        let lines = ["交易成功","甲书店","实付13.69","交易成功","乙书店","实付16.55"]
        let blocks = lines.enumerated().map { i,text in OCRBlock(text:text,boundingBox:CGRect(x:i < 3 ? 0.05 : 0.55,y:0.8-Double(i % 3)*0.06,width:0.38,height:0.025),confidence:0.95) }
        let layout = LayoutAnalysis(document:OCRDocument(rawText:lines.joined(separator:"\n"),blocks:blocks,recognitionLanguage:"zh-Hans",engineVersion:"synthetic-two-columns"))
        let item = try accepted(GroundedExtraction.direct(layout))
        XCTAssertEqual(Set(item.recognizedScenes?.compactMap { $0.fields.first { $0.kind == .amount }?.value } ?? []),Set(["13.69","16.55"]))
    }
    func testMixedScenePriorityAndScope() throws {
        let layout = LayoutAnalysis(document:doc(["取餐码55", "街角茶店", "实付7.7", "支付成功", "实付37.66", "赵一鸣"] ))
        let item = try accepted(GroundedExtraction.direct(layout))
        XCTAssertEqual(item.category,.pickup); XCTAssertEqual(item.amount,"7.7")
        XCTAssertEqual(item.recognizedScenes?.count,2)
        XCTAssertEqual(item.recognizedScenes?.last?.fields.first { $0.kind == .amount }?.value,"37.66")
    }
    func testNoArrangementEvidenceCannotBecomeReviewCalendar() throws {
        for lines in [["微信","明天下午开会吗"],["准备下个月旅游"],["公开活动海报","请于10月3日参加读书会"],["公开活动海报","请于10月3日参加设计会议"],["文章发布时间：2026年10月3日09:30"],["已订阅开场提醒","10月3日19:30"]] {
            let layout = LayoutAnalysis(document:doc(lines))
            let fields = layout.candidates.filter { $0.kind == "eventTime" }.map(\.id)
            let subject = layout.candidates.first { $0.kind == "subject" }?.id ?? -1
            let decision = try GroundedExtraction.validate(.init(s:[.init(c:"event",r:0,n:subject,f:fields,e:Array(layout.blocks.indices),a:"confirmed")],u:"content"),layout:layout)
            if case .accepted = decision { XCTFail(lines.joined(separator:"\n")) }
        }
    }
    func testInvoiceButtonIsNotAPurchaseVoucher() throws {
        let layout = LayoutAnalysis(document:doc(["AirPods 5", "商品报价RMB999", "可开发票", "立即购买"]))
        let subject = try XCTUnwrap(layout.candidates.first { $0.kind == "subject" })
        let decision = try GroundedExtraction.validate(.init(s:[.init(c:"documentation",r:0,n:subject.id,f:[],e:[2],a:"none")],u:"content"),layout:layout)
        if case .accepted = decision { XCTFail("开票功能不能证明持有凭证") }
    }
    func testMedicalQuestionIsNotConfirmedAndPreparationStaysLocal() throws {
        for text in ["明天上午九点到市口腔医院就诊吗？", "如果明天上午九点到市口腔医院就诊"] {
            let layout = LayoutAnalysis(document:doc([text]))
            let subject = try XCTUnwrap(layout.candidates.first { $0.kind == "subject" })
            let decision = try GroundedExtraction.validate(.init(s:[.init(c:"event",r:0,n:subject.id,f:layout.candidates.filter { $0.kind == "eventTime" }.map(\.id),e:[0],a:"confirmed")],u:"content"),layout:layout)
            if case .accepted = decision { XCTFail(text) }
        }
        let valid = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["复诊安排", "请您明天上午九点到市口腔医院就诊，准备医保卡"])) ))
        XCTAssertEqual(valid.category,.event)
        XCTAssertEqual(valid.fields.first { $0.kind == .eventTime }?.value,"明天上午九点")
    }
    func testChunkRequiresPrintedCandidateIDNotJustMatchingValue() throws {
        let layout = LayoutAnalysis(document:doc(["交易成功","甲书店","实付4.7","交易成功","乙书店","实付4.7"]))
        let table = SelectionInput.fieldTable(layout)
        let amounts = table.filter { $0.kind == "amount" }
        XCTAssertEqual(amounts.count,2)
        let index = try XCTUnwrap(table.firstIndex { $0.id == amounts[0].id })
        let payload = "\(index)=实付 \"4.7\" r1@[2]"
        XCTAssertTrue(SelectionInput.visible(amounts[0],layout:layout,in:payload))
        XCTAssertFalse(SelectionInput.visible(amounts[1],layout:layout,in:payload))
    }
    func testCheckoutIsNotActualPayment() throws {
        for lines in [["AirPods 5","支付金额37.66","确认支付"],["AirPods 5","实付37.66","待付款","立即支付"]] {
            let layout = LayoutAnalysis(document:doc(lines))
            XCTAssertTrue(layout.candidates.filter { $0.kind == "amount" }.isEmpty)
            XCTAssertNil(try GroundedExtraction.direct(layout))
            let subject = try XCTUnwrap(layout.candidates.first { $0.kind == "subject" })
            let decision = try GroundedExtraction.validate(.init(s:[.init(c:"payment",r:0,n:subject.id,f:[],e:[1],a:"none")],u:"content"),layout:layout)
            if case .accepted = decision { XCTFail("付款按钮不证明已付款") }
        }
        let completed = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["转账成功", "付款金额3400.00", "合欢公寓"])) ))
        XCTAssertEqual(completed.amount,"3400.00")
    }
    func testRelativeDateAndChineseClockAcrossBlocks() throws {
        for time in ["下周一上午9点","去年10月3日09:30"] {
            let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["会议定在" + time]))))
            XCTAssertEqual(item.fields.first { $0.kind == .eventTime }?.value,time)
        }
        for lines in [["会议定在明天","下午三点","请准备材料"],["预约详情","牙科复诊","明天","下午三点"]] {
            let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(lines))))
            XCTAssertEqual(item.fields.first { $0.kind == .eventTime }?.value,"明天\n下午三点")
            XCTAssertEqual(item.state,.pending)
        }
    }
    func testExplicitAdministrativeAddressAndShortRecipient() throws {
        let layout = LayoutAnalysis(document:doc(["西湖", "地址：浙江省杭州市西湖区"]))
        XCTAssertEqual(layout.candidates.first { $0.kind == "address" }?.value,"浙江省杭州市西湖区")
        XCTAssertTrue(SelectionInput.usefulSubject("西湖"))
        XCTAssertFalse(SelectionInput.usefulSubject("地址"))
        let address = try XCTUnwrap(layout.candidates.first { $0.kind == "address" })
        let subject = try XCTUnwrap(layout.candidates.first { $0.kind == "subject" && $0.value == "西湖" })
        let item = try accepted(GroundedExtraction.validate(.init(s:[.init(c:"place",r:0,n:subject.id,f:[address.id],e:[0,1],a:"reference")],u:"content"),layout:layout))
        XCTAssertEqual(item.title,"西湖")
        let receipt = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["收款方：张三", "实付37.66"])) ))
        XCTAssertEqual(receipt.title,"张三")
    }
    func testSplitNegativeMoneyLabelsCannotBecomePaid() throws {
        for role in ["原价","优惠","余额","退款金额"] {
            let layout = LayoutAnalysis(document:doc(["支付成功",role,"¥100","收款方","张三"]))
            XCTAssertTrue(layout.candidates.filter { $0.kind == "amount" }.isEmpty,role)
        }
        let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["收款方：张三","实际支付","¥37.66","优惠","¥5.00"])) ))
        XCTAssertEqual(item.amount,"37.66")
    }
    func testStatusOnlyCannotCreateEmptyCard() throws {
        let layout = LayoutAnalysis(document:doc(["支付成功"]))
        let status = try XCTUnwrap(layout.candidates.first { $0.kind == "orderStatus" })
        XCTAssertThrowsError(try GroundedExtraction.validate(.init(s:[.init(c:"payment",r:0,n:-1,f:[status.id],e:[0],a:"none")],u:"content"),layout:layout))
    }
    func testMultipleExplicitOwnersDoNotAttachMoneyToFirstOwner() throws {
        let layout = LayoutAnalysis(document:doc(["收款方：甲商店","收款方：乙商店","实际支付37.66"]))
        let item = try accepted(GroundedExtraction.direct(layout))
        XCTAssertEqual(item.title,"付款凭证")
        XCTAssertFalse(item.fields.contains { $0.kind == .merchant })
        XCTAssertEqual(item.amount,"37.66"); XCTAssertEqual(item.state,.needsReview)
    }
    func testCompactPackingCoversLongTailAndActualBudget() throws {
        let tokenizer = CharacterTokenizer()
        let lines = (0..<35).map { "段落\($0)：这是资料正文，包含完整的信息。" } + [String(repeating:"长段落正文，",count:350)+"最后一段凭55取餐"]
        let layout = LayoutAnalysis(document:doc(lines))
        let chunks = try SelectionInput.chunks(layout,tokenizer:tokenizer,limit:1200)
        XCTAssertGreaterThan(chunks.count,1)
        for line in lines.dropLast() { XCTAssertTrue(chunks.contains { $0.contains(line) },line) }
        XCTAssertTrue(chunks.contains { $0.contains("最后一段凭55取餐") })
        for chunk in chunks {
            let count = try tokenizer.applyChatTemplate(messages:[["role":"system","content":SelectionPolicy.instructions],["role":"user","content":chunk]],tools:nil,additionalContext:["enable_thinking":false]).count
            XCTAssertLessThanOrEqual(count,1200)
        }
    }

    func judged(_ category: String, _ arrangement: String, _ evidence: [Int], _ document: OCRDocument) throws -> ExtractionDecision {
        let name = ["领取":"领取通知","日程":"明确安排","消费":"付款凭证","收藏":"参考收藏"][category] ?? category
        let output = "{\"category\":\"\(name)\",\"arrangement\":\"\(arrangement)\"}"
        let layout = LayoutAnalysis(document:document)
        return try SceneJudgmentPolicy.validate(SceneJudgmentPolicy.decode(output,layout:layout),layout:layout)
    }
    func testSceneOnlyJudgmentLocallyBuildsFields() throws {
        let pickup = try accepted(judged("领取","无",[1],doc(["街角茶店","取餐码","55"])))
        XCTAssertEqual(pickup.code,"55"); XCTAssertEqual(pickup.category,.pickup)
        let receipt = try accepted(judged("消费","无",[1],doc(["商户：街角咖啡","支付成功","实际支付","¥37.66","优惠：5.00","余额：100"])))
        XCTAssertEqual(receipt.amount,"37.66"); XCTAssertEqual(receipt.title,"街角咖啡")
        XCTAssertFalse(receipt.fields.contains { $0.kind == .amount && $0.value != "37.66" })
        let schedule = try accepted(judged("日程","确认",[0],doc(["就诊预约详情","事项：牙科复诊","就诊时间：10月5日15:30","地点：人民医院"])))
        XCTAssertEqual(schedule.category,.event)
        XCTAssertTrue(schedule.fields.contains { $0.kind == .eventTime && $0.value.contains("15:30") })
    }
    func testSceneOnlyJudgmentCannotMakeUnconfirmedCalendar() throws {
        for lines in [["微信","明天下午开会吗"],["公开活动海报","10月5日15:00读书会"],["营业时间：09:00-18:00"],["已取消预约","10月5日15:00"]] {
            let result = try judged("日程","确认",[lines.count-1],doc(lines))
            if case .accepted(let item) = result { XCTFail("No confirmed arrangement: \(item.title)") }
        }
        let pending = try accepted(judged("日程","确认",[0],doc(["预约详情","事项：牙科复诊"])))
        XCTAssertEqual(pending.state,.needsReview)
        XCTAssertFalse(pending.fields.contains { $0.kind == .eventTime })
    }
    func testSceneOnlyReferenceDoesNotPromotePriceToPaid() throws {
        let item = try accepted(judged("收藏","参考",[0,1],doc(["城市跑鞋系列","商品选购","参考价：¥299","原价：399"])))
        XCTAssertEqual(item.category.group,.collections); XCTAssertEqual(item.amount,"")
        XCTAssertFalse(item.fields.contains { $0.kind == .amount || $0.kind == .eventTime })
        let chat = try judged("收藏","参考",[0,1],doc(["微信","今天下雨了记得带伞"]))
        if case .accepted = chat { XCTFail("Ordinary chat is not a collection") }
    }
    func testSceneJudgmentUncertainAndMalformedRemainFailures() throws {
        let layout = LayoutAnalysis(document:doc(["未能确定用途的页面"]))
        let uncertain = try SceneJudgmentPolicy.decode("{\"category\":\"不确定\",\"arrangement\":\"无\"}",layout:layout)
        XCTAssertThrowsError(try GroundedExtraction.validate(uncertain,layout:layout))
        let ignored = try SceneJudgmentPolicy.decode("{\"category\":\"无关\",\"arrangement\":\"无\"}",layout:layout)
        if case .accepted = try GroundedExtraction.validate(ignored,layout:layout) { XCTFail("Ignored must not create cards") }
        XCTAssertThrowsError(try SceneJudgmentPolicy.decode("{\"category\":\"参考收藏\",\"arrangement\":\"参考\",\"evidence\":[999]}",layout:layout))
        XCTAssertThrowsError(try SceneJudgmentPolicy.decode("{\"category\":\"参考收藏\",\"arrangement\":\"参考\",\"fields\":[0]}",layout:layout))
        XCTAssertThrowsError(try SceneJudgmentPolicy.decode("{\"category\":\"参考收藏\",\"arrangement\":\"参考\"}",layout:layout,payload:"[1] r0 未显示块0"))
        XCTAssertThrowsError(try judged("消费","无",[0],doc(["城市跑鞋系列","参考价：¥299","商品选购"])))
    }
    func testSceneInputCoversLongTailWithoutFieldTables() throws {
        let tokenizer = CharacterTokenizer()
        let lines = (0..<35).map { "资料正文\($0)：介绍页面中的有效内容。" } + [String(repeating:"这是长段落正文，",count:300)+"最后一段凭55取餐"]
        let layout = LayoutAnalysis(document:doc(lines))
        let chunks = try SceneJudgmentInput.chunks(layout,tokenizer:tokenizer,limit:1200)
        XCTAssertGreaterThan(chunks.count,1)
        for line in lines.dropLast() { XCTAssertTrue(chunks.contains { $0.contains(line) },line) }
        XCTAssertTrue(chunks.contains { $0.contains("最后一段凭55取餐") })
        for chunk in chunks {
            XCTAssertLessThanOrEqual(try SceneJudgmentInput.count(chunk,tokenizer:tokenizer),1200)
            XCTAssertFalse(chunk.contains("字段候选")); XCTAssertFalse(chunk.contains("主体候选"))
        }
        XCTAssertFalse(SceneJudgmentPolicy.schema.contains("subject"))
        XCTAssertFalse(SceneJudgmentPolicy.schema.contains("fields"))
        XCTAssertFalse(SceneJudgmentPolicy.schema.contains("evidence"))
    }
    func testRejectedWrongSceneOnlySkipsClearNegatives() throws {
        for lines in [["1234","5678"],["09:41","5G","123456"],["09:41","86%","123456"],["订单号：202610030001"],["微信","明天下午开会吗","再说吧"],["微信","今天吃什么","火锅吧"],["新闻","文章发布时间：2026年10月3日09:30","城市今天发布天气资讯"]] {
            do {
                let result = try judged("领取","无",[],doc(lines))
                if case .accepted = result { XCTFail("Clear negative cannot create a card: \(lines)") }
            } catch { XCTFail("Clear negative should skip: \(lines), error: \(error)") }
        }
        for lines in [["城市跑鞋系列","参考价：¥299","商品选购"],["微信","会议通知：明天15:00开会"],["微信","凭55领取餐食"],["未知来源","这是一段无法可靠判定用途的文字"]] {
            let layout = LayoutAnalysis(document:doc(lines))
            XCTAssertFalse(SceneJudgmentPolicy.clearlyUnrelated(layout))
        }
        let uncertain = try SceneJudgmentPolicy.decode("{\"category\":\"不确定\",\"arrangement\":\"无\"}",layout:LayoutAnalysis(document:doc(["1234"])))
        XCTAssertThrowsError(try SceneJudgmentPolicy.validate(uncertain,layout:LayoutAnalysis(document:doc(["1234"]))))
        var lowConfidence = doc(["1234"]); lowConfidence.blocks[0].confidence = 0.2
        XCTAssertFalse(SceneJudgmentPolicy.clearlyUnrelated(LayoutAnalysis(document:lowConfidence)))
        let pickup = LayoutAnalysis(document:doc(["取餐码55","街角茶店"]))
        let wrongIgnore = try SceneJudgmentPolicy.decode("{\"category\":\"无关\",\"arrangement\":\"无\"}",layout:pickup)
        XCTAssertThrowsError(try SceneJudgmentPolicy.validate(wrongIgnore,layout:pickup))
        if case .accepted = try SceneJudgmentPolicy.validate(wrongIgnore,layout:pickup,checkIgnoreProof:false) { XCTFail("An ignored segment has no card; remaining segments still run") }
    }

    func testCollectionNeedsReusableInformationNotJustTopicOrLongText() throws {
        let negatives = [
            ["微信", "只是看到了一个酒店，感觉很漂亮。", "大家都说这家店很不错，有空再去吧。", "今天没有什么特别的安排，聊聊就好。"],
            ["欢迎来到直播间", "大学同学都在这里", "关注", "粉丝", "评论"],
            ["个人主页", "某大学学生", "作品30", "关注我", "酒店真的好看"],
            ["新闻", "今天科技公司发布新款机器人。", "这家企业拥有广泛的市场份额。", "发布于浙江", "评论"],
            ["会员优惠", "升级你的风格", "年度计划", "¥33/月", "开始7天免费试用"],
            ["当前门店商品可用卡券", "学校餐厅店", "商品优惠券", "¥4.9", "优惠券"],
            ["当前门店商品可用卡劵", "学校餐厅店", "商品优惠券", "¥4.9", "优惠券"],
            ["新华网", "海南大学研究生失联", "警方正在了解", "热点", "某大学附近", "评论"],
            ["中央气象台", "台风路径概率预报图", "27日20:00", "28日20:00", "旅客列车临时停运", "热点", "评论"],
            ["微信", "你明天去那个酒店吗？", "还没有确定，不知道价格。"]
        ]
        for lines in negatives {
            if case .accepted = try judged("收藏","参考",[],doc(lines)) { XCTFail("Not reusable collection: \(lines)") }
        }
    }
    func testCollectionKeepsConcreteReferenceAndMap() throws {
        for lines in [
            ["城市跑鞋系列", "商品选购", "规格：透气网面，尺码39-44", "参考价：¥299"],
            ["未来设计工作坊", "公开活动", "活动日期：10月8日14:00", "活动地点：杭州市大学路20号"],
            ["东门地铁站", "路线导航", "地址：杭州市学院路20号"],
            ["设备设置操作指南", "第一步：打开设备设置并找到显示菜单。", "第二步：选择护眼模式后保存配置。"]
        ] {
            let item = try accepted(judged("收藏","参考",[],doc(lines)))
            XCTAssertEqual(item.category.group,.collections)
            XCTAssertFalse(item.fields.contains { $0.kind == .eventTime || $0.kind == .amount })
        }
    }
    func testModelCanIgnoreIncidentalURLWithoutLosingBusinessProof() throws {
        let layout = LayoutAnalysis(document:doc(["新闻", "商品上市的简短报道", "来源：https://example.com/news"]))
        let response = try SceneJudgmentPolicy.decode("{\"category\":\"无关\",\"arrangement\":\"无\"}",layout:layout)
        if case .accepted = try SceneJudgmentPolicy.validate(response,layout:layout) { XCTFail("Incidental URL cannot force admission") }
    }
    func testSocialCountsAreNotReferencePrices() throws {
        let layout = LayoutAnalysis(document:doc(["直播团购关注商城推荐", "9.2万", "很多年没有在路边蹲着吃", "4700", "1.5万"]))
        XCTAssertFalse(layout.candidates.contains { $0.kind == "price" })
    }
    func testPublicPosterIsReferenceEvenIfModelClaimsPersonalSchedule() throws {
        let item = try accepted(judged("日程","确认",[],doc(["未来设计工作坊", "公开活动", "活动日期：10月8日14:00", "活动地点：杭州市大学路20号"])))
        XCTAssertEqual(item.category.group,.collections)
        XCTAssertFalse(item.fields.contains { $0.kind == .eventTime || $0.kind == .amount })
    }
    func testCompletedOrderWithChevronKeepsActualPaid() throws {
        let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(["订单已完成>","街角饭店", "实付", "¥14.1>"]))))
        XCTAssertEqual(item.category,.shopping)
        XCTAssertEqual(item.amount,"14.1")
    }
    func testMarketNewsIsNotAnAddressAndPendingVenueIsNotCompleteActivity() throws {
        let news = LayoutAnalysis(document:doc(["某商品上市大涨近200%", "昨天刚上市，就一路大涨，让所有人都惊讶。", "评论"]))
        XCTAssertFalse(news.candidates.contains { $0.kind == "address" })
        let nearby = doc(["新闻", "同学在某大学附近与朋友分开，家人急切询问情况。", "目前尚无确切消息，记者正在了解。", "评论"])
        if case .accepted = try judged("收藏","参考",[],nearby) { XCTFail("A nearby school mention is not a map") }
        if case .accepted = try judged("收藏","参考",[],news.document) { XCTFail("Market wording is not an address") }
        let pending = doc(["嘉兴站演唱会报批更新", "演出时间：8月14日起", "演出地点：待定", "一切以官宣为准。"])
        if case .accepted = try judged("收藏","参考",[],pending) { XCTFail("No actual venue") }
    }
    func testRestaurantCollectionAliasesRetainLiteralCode() throws {
        for lines in [["取餈码", "7284", "门店已接单，请于下单当日及时到店取餐", "学校餐厅店"], ["商家已接单", "取单号：C59", "街角餐厅", "实付¥18", "订单编号", "2100005535796929"]] {
            let item = try accepted(GroundedExtraction.direct(LayoutAnalysis(document:doc(lines))))
            XCTAssertEqual(item.category,.pickup)
            XCTAssertEqual(item.code,lines[0] == "取餈码" ? "7284" : "C59")
            XCTAssertNotEqual(item.title,"订单编号")
        }
    }
    func testFlightComparisonDoesNotRequireBookingTimeLabels() throws {
        let item = try accepted(judged("收藏","参考",[],doc(["深圳－新加坡", "仅看直飞", "12:35", "16:40", "¥1397", "02:05", "06:10", "¥1320"])))
        XCTAssertEqual(item.category.group,.collections)
        XCTAssertFalse(item.fields.contains { $0.kind == .eventTime || $0.kind == .amount })
    }
    func testOrderNumberIsNotPickupCode() throws {
        let layout = LayoutAnalysis(document:doc(["配餐中", "订单号", "35664", "待取餐", "麦当劳小和山餐厅"]))
        XCTAssertFalse(layout.candidates.contains { $0.kind == "code" })
    }
    func testUrgentAssignedActionCanRemainReviewWithoutInventedTime() throws {
        let document = doc(["关于地下车库台风期间紧急挪车的通知", "各位同学：", "请所有停放于地下车库的车辆", "车主，立即将车辆挪至地面安全区域停放。"])
        let item = try accepted(judged("日程","通知",[],document))
        XCTAssertEqual(item.category,.event)
        XCTAssertEqual(item.state,.needsReview)
        XCTAssertFalse(item.fields.contains { $0.kind == .eventTime })
    }

}

private struct CharacterTokenizer: MLXLMCommon.Tokenizer {
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func encode(text:String,addSpecialTokens:Bool) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func decode(tokenIds:[Int],skipSpecialTokens:Bool) -> String { String(String.UnicodeScalarView(tokenIds.compactMap { UnicodeScalar($0) })) }
    func convertTokenToId(_ token:String) -> Int? { token.unicodeScalars.first.map { Int($0.value) } }
    func convertIdToToken(_ id:String) -> String? { nil }
    func convertIdToToken(_ id:Int) -> String? { UnicodeScalar(id).map { String($0) } }
    func applyChatTemplate(messages:[[String:any Sendable]],tools:[[String:any Sendable]]?,additionalContext:[String:any Sendable]?) throws -> [Int] {
        encode(text:messages.compactMap { $0["content"] as? String }.joined(separator:"\n"),addSpecialTokens:false)
    }

}
