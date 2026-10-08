import CoreGraphics
import Foundation

enum Category: String, Codable, CaseIterable, Hashable {
    case delivery
    case pickup
    case payment
    case event
    case shopping
    case place
    case learning
    case health
    case social
    case technical
    case documentation
    case inspiration
    case other

    var displayName: String {
        switch self {
        case .delivery: return "物流"
        case .pickup: return "餐饮 / 取餐"
        case .payment: return "消费 / 付款"
        case .event: return "活动 / 日程"
        case .shopping: return "购物"
        case .place: return "地点 / 旅行"
        case .learning: return "学习 / 资料"
        case .health: return "健康"
        case .social: return "闲聊"
        case .technical: return "教程 / 设置"
        case .documentation: return "凭证 / 记录"
        case .inspiration: return "灵感 / 记忆"
        case .other: return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .delivery: return "shippingbox"
        case .pickup: return "takeoutbag.and.cup.and.straw"
        case .payment: return "creditcard"
        case .event: return "calendar"
        case .shopping: return "bag"
        case .place: return "map"
        case .learning: return "book"
        case .health: return "cross.case"
        case .social: return "bubble.left.and.bubble.right"
        case .technical: return "wrench.and.screwdriver"
        case .documentation: return "doc.text"
        case .inspiration: return "sparkles"
        case .other: return "doc.text.image"
        }
    }

    var cardFields: [CategoryCardField] {
        switch self {
        case .delivery:
            return [Self.field("取货码", .code), Self.field("快递驿站", .parcelStation)]
        case .pickup:
            return [Self.field("餐厅 / 门店", .venue, fallbacks: [.merchant, .location]), Self.field("取餐号码", .code)]
        case .payment:
            return [Self.field("付款商户", .merchant), Self.field("实付金额", .amount)]
        case .event:
            return [Self.field("活动名称", .eventName), Self.eventDateTime("活动时间")]
        case .shopping:
            return [Self.field("商品名称", .product), Self.field("实付金额", .amount)]
        case .place:
            return [Self.field("地点名称", .location), Self.field("地址 / 路线", .address, fallbacks: [.route])]
        case .learning:
            return [Self.title("资料标题"), Self.field("课程 / 主题", .topic)]
        case .health:
            return [Self.field("检查 / 药品项目", .healthItem), Self.field("就诊 / 检查日期", .date)]
        case .social:
            return [Self.title("聊天内容"), Self.field("消息摘录", .excerpt)]
        case .technical:
            return [Self.field("操作对象", .operationTarget), Self.field("问题 / 操作步骤", .issueSteps, fallbacks: [.excerpt])]
        case .documentation:
            return [Self.field("凭证类型", .documentType), Self.field("凭证编号 / 日期", .documentReference, fallbacks: [.date])]
        case .inspiration:
            return [Self.title("内容标题"), Self.field("文字摘录", .excerpt)]
        case .other:
            return [Self.title("截图标题"), Self.field("文字摘录", .excerpt)]
        }
    }

    private static func field(_ label: String, _ kind: FieldKind, fallbacks: [FieldKind] = []) -> CategoryCardField {
        CategoryCardField(label: label, source: .fields(primary: kind, fallbacks: fallbacks))
    }

    private static func title(_ label: String) -> CategoryCardField {
        CategoryCardField(label: label, source: .title)
    }

    private static func eventDateTime(_ label: String) -> CategoryCardField {
        CategoryCardField(label: label, source: .eventDateTime)
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "快递", "delivery": self = .delivery
        case "取餐", "餐饮 / 取餐", "pickup": self = .pickup
        case "消费凭证", "消费 / 付款", "payment": self = .payment
        case "活动", "活动 / 日程", "event": self = .event
        case "shopping", "购物": self = .shopping
        case "place", "地点 / 旅行": self = .place
        case "learning", "学习 / 资料": self = .learning
        case "health", "健康": self = .health
        case "social", "闲聊", "社交 / 聊天": self = .social
        case "technical", "教程 / 设置": self = .technical
        case "documentation", "凭证 / 记录": self = .documentation
        case "inspiration", "灵感 / 记忆": self = .inspiration
        default: self = .other
        }
    }
}

enum CategoryGroup: String, CaseIterable, Identifiable, Hashable {
    case collectionCodes
    case schedules
    case purchases
    case collections
    case conversations

    var id: Self { self }

    var displayName: String {
        switch self {
        case .collectionCodes: return "取货码 / 取件码"
        case .schedules: return "日程 / 预约 / 出行"
        case .purchases: return "消费 / 订单 / 凭证"
        case .collections: return "资料 / 地点 / 灵感收藏"
        case .conversations: return "闲聊"
        }
    }

    var symbol: String {
        switch self {
        case .collectionCodes: return "shippingbox"
        case .schedules: return "calendar"
        case .purchases: return "creditcard"
        case .collections: return "bookmark"
        case .conversations: return "bubble.left.and.bubble.right"
        }
    }
}

extension Category {
    var group: CategoryGroup {
        switch self {
        case .delivery, .pickup: return .collectionCodes
        case .event, .health: return .schedules
        case .payment, .shopping, .documentation: return .purchases
        case .place, .learning, .technical, .inspiration, .other: return .collections
        case .social: return .conversations
        }
    }
}

enum CategoryCardFieldSource: Hashable {
    case title
    case fields(primary: FieldKind, fallbacks: [FieldKind])
    case eventDateTime
}

struct CategoryCardField: Identifiable, Hashable {
    let label: String
    let source: CategoryCardFieldSource

    var id: String { label }

    var editableKind: FieldKind? {
        switch source {
        case .title: return nil
        case .fields(let primary, _): return primary
        case .eventDateTime: return .eventTime
        }
    }

    func displayValue(for item: InformationItem) -> String {
        item.cardValue(for: self) ?? "待识别"
    }
}

enum IntentTag: String, Codable, CaseIterable, Hashable {
    case reviewLater
    case purchaseCandidate
    case planning
    case evidence
    case share
    case offline
    case favorite
    case memory

    var displayName: String {
        switch self {
        case .reviewLater: return "稍后查看"
        case .purchaseCandidate: return "购买候选"
        case .planning: return "行程计划"
        case .evidence: return "凭证留存"
        case .share: return "待分享"
        case .offline: return "离线参考"
        case .favorite: return "收藏"
        case .memory: return "记忆保存"
        }
    }

    var symbol: String {
        switch self {
        case .reviewLater: return "clock"
        case .purchaseCandidate: return "cart"
        case .planning: return "map"
        case .evidence: return "checkmark.seal"
        case .share: return "square.and.arrow.up"
        case .offline: return "arrow.down.circle"
        case .favorite: return "bookmark"
        case .memory: return "heart"
        }
    }
}

enum ItemState: String, Codable, CaseIterable, Hashable {
    case needsReview
    case pending
    case completed
    case archived

    var displayName: String {
        switch self {
        case .needsReview: return "需重新处理"
        case .pending: return "待处理"
        case .completed: return "已完成"
        case .archived: return "已归档"
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "待确认", "needsReview": self = .needsReview
        case "待处理", "pending": self = .pending
        case "已完成", "completed": self = .completed
        case "已归档", "archived": self = .archived
        default: self = .needsReview
        }
    }
}

enum FieldKind: String, Codable, CaseIterable, Hashable {
    case code, amount, date, time, location, address, url, merchant, product, contact, note
    case deadline, orderStatus
    case parcelStation, venue, eventName, eventTime, price, route, topic, healthItem
    case conversationPartner, excerpt, operationTarget, issueSteps, documentType, documentReference

    /// These fields contain complementary source fragments or reference resources,
    /// rather than competing answers to one question (such as the paid amount).
    var isRepeatableContent: Bool {
        [.excerpt, .issueSteps, .url, .route].contains(self)
    }

    var displayName: String {
        switch self {
        case .deadline: return "截止时间"
        case .orderStatus: return "订单状态"
        case .code: return "取件码 / 取餐号"
        case .amount: return "金额"
        case .date: return "日期"
        case .time: return "时间"
        case .location: return "地点"
        case .address: return "地址"
        case .url: return "链接"
        case .merchant: return "商户"
        case .product: return "商品"
        case .contact: return "联系方式"
        case .note: return "备注"
        case .parcelStation: return "快递驿站"
        case .venue: return "餐厅 / 门店"
        case .eventName: return "活动名称"
        case .eventTime: return "活动时间"
        case .price: return "商品价格"
        case .route: return "路线"
        case .topic: return "课程 / 主题"
        case .healthItem: return "检查 / 药品项目"
        case .conversationPartner: return "联系人 / 群聊"
        case .excerpt: return "文字摘录"
        case .operationTarget: return "操作对象"
        case .issueSteps: return "问题 / 操作步骤"
        case .documentType: return "凭证类型"
        case .documentReference: return "凭证编号"
        }
    }
}

struct OCRBlock: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String
    var boundingBox: CGRect
    var confidence: Double
}

struct OCRDocument: Codable, Hashable {
    var rawText: String
    var blocks: [OCRBlock]
    var recognitionLanguage: String
    var engineVersion: String
    /// Legacy transient image slot; the current OCR/SLM path leaves it empty.
    /// Never encoded into cards, jobs or OCR caches.
    var sourceImageData: Data? = nil
    enum CodingKeys: String, CodingKey {
        case rawText, blocks, recognitionLanguage, engineVersion
    }
    var textOnly: OCRDocument {
        var copy = self; copy.sourceImageData = nil; return copy
    }
}

struct ExtractedField: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: FieldKind
    var value: String
    var confidence: Double
    var sourceBlockIDs: [UUID]
    var isUserEdited: Bool = false
    var unit: String? = nil
    var currency: String? = nil

    var displayValue: String {
        if isUserEdited { return value }
        let prefix = currency.map { value.hasPrefix($0) ? "" : $0 } ?? ""
        let suffix: String
        if let unit, !value.contains("万"), !value.hasSuffix(unit) { suffix = unit } else { suffix = "" }
        return prefix + value + suffix
    }
}

struct RecognizedScene: Codable, Identifiable {
    var id: UUID = UUID()
    var category: Category
    var title: String
    var fields: [ExtractedField]
    var contentNature: String
    var reviewReasons: [String]
    var reprocessingReasons: [ReprocessingReason]? = nil
}

/// Retained for compatibility with cards saved by the confirmation workflow.
enum DisplayApproval: String, Codable {
    case automatic
    case userConfirmed
}

struct InformationItem: Identifiable, Codable {
    var id = UUID()
    var createdAt = Date()
    var category: Category
    var title: String
    var rawText: String
    var code: String = ""
    var amount: String = ""
    var note: String = ""
    var state: ItemState = .needsReview
    var reminderAt: Date?
    var imageName: String = ""
    var fingerprint: String = ""
    var photoAssetIdentifier: String? = nil
    var photoAssetCreatedAt: Date? = nil
    var titleWasUserEdited: Bool = false
    var categoryWasUserEdited: Bool = false
    var intents: [IntentTag] = []
    var fields: [ExtractedField] = []
    var ocrDocument: OCRDocument?
    var classificationConfidence: Double = 0
    var matchedKeywords: [String] = []
    var classificationVersion: String = "rules-v3"
    var contentNature: String? = nil
    var reviewReasons: [String]? = nil
    var recognizedScenes: [RecognizedScene]? = nil
    var displayApproval: DisplayApproval? = nil
    var reprocessingReasons: [ReprocessingReason]? = nil

    var displayState: ItemState { state }
    var needsReprocessing: Bool { state == .needsReview }

    /// Complete cards appear immediately, without a manual approval step.
    mutating func prepareForDisplay(preserveFinalState: Bool = true) {
        let requestedState = state
        let finalState = state == .completed || state == .archived
        guard !preserveFinalState || !finalState else { return }
        reprocessingReasons = CardCompleteness.evaluate(self)
        state = reprocessingReasons?.isEmpty == false ? .needsReview : finalState ? requestedState : .pending
        displayApproval = state == .pending ? .automatic : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, category, title, rawText, code, amount, note, state, reminderAt, imageName, fingerprint
        case contentNature, reviewReasons, recognizedScenes, displayApproval, reprocessingReasons
        case photoAssetIdentifier, photoAssetCreatedAt, titleWasUserEdited, categoryWasUserEdited, intents, fields, ocrDocument, classificationConfidence, matchedKeywords, classificationVersion
    }

    init(category: Category, title: String, rawText: String) {
        self.category = category
        self.title = title
        self.rawText = rawText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        category = try container.decodeIfPresent(Category.self, forKey: .category) ?? .other
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "未识别文字"
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
        amount = try container.decodeIfPresent(String.self, forKey: .amount) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        state = try container.decodeIfPresent(ItemState.self, forKey: .state) ?? .needsReview
        reminderAt = try container.decodeIfPresent(Date.self, forKey: .reminderAt)
        imageName = try container.decodeIfPresent(String.self, forKey: .imageName) ?? ""
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        photoAssetIdentifier = try container.decodeIfPresent(String.self, forKey: .photoAssetIdentifier)
        photoAssetCreatedAt = try container.decodeIfPresent(Date.self, forKey: .photoAssetCreatedAt)
        titleWasUserEdited = try container.decodeIfPresent(Bool.self, forKey: .titleWasUserEdited) ?? false
        categoryWasUserEdited = try container.decodeIfPresent(Bool.self, forKey: .categoryWasUserEdited) ?? false
        intents = try container.decodeIfPresent([IntentTag].self, forKey: .intents) ?? []
        fields = try container.decodeIfPresent([ExtractedField].self, forKey: .fields) ?? []
        ocrDocument = try container.decodeIfPresent(OCRDocument.self, forKey: .ocrDocument)
        classificationConfidence = try container.decodeIfPresent(Double.self, forKey: .classificationConfidence) ?? 0
        matchedKeywords = try container.decodeIfPresent([String].self, forKey: .matchedKeywords) ?? []
        classificationVersion = try container.decodeIfPresent(String.self, forKey: .classificationVersion) ?? "rules-v1"
        contentNature = try container.decodeIfPresent(String.self, forKey: .contentNature)
        reviewReasons = try container.decodeIfPresent([String].self, forKey: .reviewReasons)
        recognizedScenes = try container.decodeIfPresent([RecognizedScene].self, forKey: .recognizedScenes)
        displayApproval = try container.decodeIfPresent(DisplayApproval.self, forKey: .displayApproval)
        reprocessingReasons = try container.decodeIfPresent([ReprocessingReason].self, forKey: .reprocessingReasons)
        if fields.isEmpty {
            if !code.isEmpty { fields.append(ExtractedField(kind: .code, value: code, confidence: 1, sourceBlockIDs: [])) }
            if !amount.isEmpty { fields.append(ExtractedField(kind: .amount, value: amount, confidence: 1, sourceBlockIDs: [])) }
            if !note.isEmpty { fields.append(ExtractedField(kind: .note, value: note, confidence: 1, sourceBlockIDs: [])) }
        }
    }

    func cardValue(for slot: CategoryCardField) -> String? {
        switch slot.source {
        case .title:
            return nonempty(title)
        case .fields(let primary, let fallbacks):
            if let primaryField = fields.first(where: { $0.kind == primary }) {
                if primaryField.isUserEdited { return nonempty(primaryField.value) }
                if let value = nonempty(primaryField.displayValue) { return value }
            }
            for kind in fallbacks {
                if let value = fields.first(where: { $0.kind == kind }).flatMap({ nonempty($0.displayValue) }) {
                    return value
                }
                let legacyValue: String
                switch kind {
                case .code: legacyValue = code
                case .amount: legacyValue = amount
                case .note: legacyValue = note
                default: legacyValue = ""
                }
                if let value = nonempty(legacyValue) { return value }
                if kind == .excerpt, let value = OCRTextExcerpt.make(from: rawText, excluding: title) { return value }
            }
            return nil
        case .eventDateTime:
            if let eventTime = fields.first(where: { $0.kind == .eventTime }) {
                if eventTime.isUserEdited { return nonempty(eventTime.value) }
                if let value = nonempty(eventTime.value) { return value }
            }
            let date = fields.first(where: { $0.kind == .date }).flatMap({ nonempty($0.displayValue) })
            let time = fields.first(where: { $0.kind == .time }).flatMap({ nonempty($0.displayValue) })
            return [date, time].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
    }

    mutating func setCardValue(_ value: String, for slot: CategoryCardField) {
        switch slot.source {
        case .title:
            title = value
            titleWasUserEdited = true
        case .fields(let kind, _):
            setUserEditedValue(value, for: kind)
        case .eventDateTime:
            setUserEditedValue(value, for: .eventTime)
        }
    }

    mutating func setUserEditedValue(_ value: String, for kind: FieldKind) {
        setUserEditedField(kind, value: value)
    }

    mutating func preserveUserEdits(from previous: InformationItem) {
        if previous.categoryWasUserEdited && !categoryWasUserEdited {
            category = previous.category
            categoryWasUserEdited = true
        }
        if previous.titleWasUserEdited && !titleWasUserEdited {
            title = previous.title
            titleWasUserEdited = true
        }
        for oldField in previous.fields where oldField.isUserEdited {
            if let index = fields.firstIndex(where: { $0.kind == oldField.kind }) {
                if !fields[index].isUserEdited { fields[index] = oldField }
            } else {
                fields.append(oldField)
            }
        }
        synchronizeLegacyValues()
    }

    private mutating func setUserEditedField(_ kind: FieldKind, value: String) {
        if let index = fields.firstIndex(where: { $0.kind == kind }) {
            fields[index].value = value
            fields[index].isUserEdited = true
        } else {
            fields.append(ExtractedField(kind: kind, value: value, confidence: 1, sourceBlockIDs: [], isUserEdited: true))
        }
        synchronizeLegacyValues()
    }

    private mutating func synchronizeLegacyValues() {
        if let field = fields.last(where: { $0.kind == .code && $0.isUserEdited }) { code = field.value }
        if let field = fields.last(where: { $0.kind == .amount && $0.isUserEdited }) { amount = field.value }
        if let field = fields.last(where: { $0.kind == .note && $0.isUserEdited }) { note = field.value }
    }

    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum OCRTextExcerpt {
    static func make(from text: String, excluding title: String = "", maxLength: Int = 56) -> String? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = text
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: {
                !$0.isEmpty && (normalizedTitle.isEmpty || ($0 != normalizedTitle && !$0.hasSuffix(normalizedTitle)))
            }) else { return nil }
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

protocol InformationExtracting {
    func extract(_ text: String) -> InformationItem
    func extract(document: OCRDocument) -> InformationItem
}

struct RuleExtractor: InformationExtracting {
    func extract(_ text: String) -> InformationItem {
        let block = OCRBlock(text: text, boundingBox: .zero, confidence: text.isEmpty ? 0 : 1)
        return extract(document: OCRDocument(rawText: text, blocks: [block], recognitionLanguage: "zh-Hans,en-US", engineVersion: "rules-v3"))
    }

    func extract(document: OCRDocument) -> InformationItem {
        let text = document.rawText
        let normalized = text.lowercased()
        let patterns: [(Category, [String], Double)] = [
            (.delivery, ["取件码", "提货码", "快递", "驿站", "配送"], 0.96),
            (.pickup, ["取餐号", "取餐码", "取餐", "外卖"], 0.96),
            (.payment, ["支付成功", "实付", "交易成功", "付款", "收款"], 0.94),
            (.event, ["活动时间", "演出时间", "会议时间", "预约", "日程", "门票"], 0.86),
            (.shopping, ["购物车", "商品", "折扣", "优惠券", "到手价", "购买", "愿望清单"], 0.82),
            (.place, ["地图", "地址", "酒店", "路线", "导航", "景点", "餐厅"], 0.82),
            (.learning, ["课程", "笔记", "作业", "练习", "讲义", "论文", "幻灯片", "学习"], 0.82),
            (.health, ["医院", "药品", "过敏", "检查", "治疗", "处方", "健康"], 0.90),
            (.social, ["聊天", "联系人", "转发", "微信", "消息", "对话", "私信"], 0.80),
            (.technical, ["设置", "安装", "错误", "报错", "操作步骤", "系统"], 0.84),
            (.documentation, ["发票", "收据", "证明", "凭证", "退款", "纠纷", "合同", "报销"], 0.88),
            (.inspiration, ["灵感", "喜欢", "收藏", "电影", "音乐", "游戏", "推荐", "金句", "壁纸"], 0.76)
        ]
        let match = patterns.first { _, keywords, _ in keywords.contains(where: normalized.contains) }
        let category = match?.0 ?? .other
        let keywords = match?.1.filter { normalized.contains($0.lowercased()) } ?? []
        let confidence = match?.2 ?? 0.2
        let title = capture("(?:资料标题|笔记标题|论文标题|内容标题|收藏标题|截图标题|活动名称|活动标题|演出名称|会议名称|商品名称|商品名|地点名称|目的地|餐厅名称|门店名称|店名|药品名称|应用名称|软件名称|设备名称|商户|商家)[：:\\s]*([^\\n，,]+)", text)
            ?? text.split(whereSeparator: { $0.isNewline }).map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? "未识别文字"
        var result = InformationItem(category: category, title: title.trimmingCharacters(in: .whitespacesAndNewlines), rawText: text)
        result.ocrDocument = document
        result.classificationConfidence = confidence
        result.matchedKeywords = keywords
        result.state = confidence >= 0.8 ? .pending : .needsReview
        result.intents = inferIntents(text: text, category: category)

        if let code = capture("(?:取件码|提货码|取餐号|取餐码)[：:\\s]*([A-Za-z0-9]+(?:[-－][A-Za-z0-9]+)*)", text) {
            result.code = code
            result.fields.append(field(.code, code, document: document, confidence: 0.98))
        }
        if let amount = capture("(?:实付(?:金额)?|实际支付|支付金额)[：:\\s]*[¥￥]?\\s*([0-9]+(?:\\.[0-9]{1,2})?)", text) {
            result.amount = amount
            result.fields.append(field(.amount, amount, document: document, confidence: 0.98))
        }
        if let date = capture("(20\\d{2}[-/.年]\\d{1,2}[-/.月]\\d{1,2}日?|\\d{1,2}月\\d{1,2}日)", text) {
            result.fields.append(field(.date, date, document: document, confidence: 0.90))
        }
        if let time = capture("(?:时间|开始|截止|预约)[：:\\s]*(?:20\\d{2}[-/.年]\\d{1,2}[-/.月]\\d{1,2}日?|\\d{1,2}月\\d{1,2}日)?[，,\\s]*(\\d{1,2}[:：]\\d{2})", text) {
            result.fields.append(field(.time, time, document: document, confidence: 0.88))
        }
        if let url = capture("(https?://[^\\s]+)", text) {
            result.fields.append(field(.url, url, document: document, confidence: 0.99))
        }
        if let address = capture("(?:收货地址|配送地址|地址)[：:\\s]*(.+)", text) {
            result.fields.append(field(.address, address, document: document, confidence: 0.88))
        }
        if let location = capture("(?:地点名称|集合地点|会议地点|目的地|景点名称|酒店名称|地点|位置)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.location, location, document: document, confidence: 0.88))
        }
        if let merchant = capture("(?:商户|商家|店铺|门店)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.merchant, merchant, document: document, confidence: 0.90))
        }
        if let product = capture("(?:商品名称|商品|产品|课程名称)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.product, product, document: document, confidence: 0.86))
        }
        if let contact = capture("(?:联系方式|联系电话|联系人)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.contact, contact, document: document, confidence: 0.86))
        }
        if let station = capture("(?:快递驿站|驿站名称|取货地点|取件地点|自提点|代收点)[：:\\s]*([^\\n，,]+)", text)
            ?? capture("(?:已到达|前往|送至|到达)([^\\n，,]{2,28}驿站)", text) {
            result.fields.append(field(.parcelStation, station, document: document, confidence: 0.90))
        }
        if let venue = capture("(?:餐厅名称|餐厅|餐馆|取餐门店|门店名称|门店|店名)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.venue, venue, document: document, confidence: 0.90))
        }
        if let eventName = capture("(?:活动名称|活动标题|演出名称|演出标题|会议名称|会议主题)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.eventName, eventName, document: document, confidence: 0.90))
        }
        if let price = capture("(?:商品价格|到手价|现价|售价|优惠价|单价)[：:\\s]*[¥￥]?\\s*([0-9]+(?:\\.[0-9]{1,2})?)", text) {
            result.fields.append(field(.price, price, document: document, confidence: 0.90))
        }
        if let route = capture("(?:行程路线|交通路线|路线)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.route, route, document: document, confidence: 0.86))
        }
        if let topic = capture("(?:课程主题|课程名称|课程|主题|科目|知识点)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.topic, topic, document: document, confidence: 0.86))
        }
        if let healthItem = capture("(?:检查项目|检查名称|检验项目|药品名称|药物名称|药品|药物|治疗项目|疫苗)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.healthItem, healthItem, document: document, confidence: 0.88))
        }
        if let partner = capture("(?:群聊名称|群聊|对话对象|联系人)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.conversationPartner, partner, document: document, confidence: 0.86))
        }
        if let target = capture("(?:应用名称|软件名称|应用|软件|设备名称|机型|操作对象)[：:\\s]*([^\\n，,]+)", text) {
            result.fields.append(field(.operationTarget, target, document: document, confidence: 0.86))
        }
        if let issue = capture("(?:问题描述|问题|错误信息|报错信息|报错|操作步骤|步骤|解决方法)[：:\\s]*([^\\n]+)", text) {
            result.fields.append(field(.issueSteps, issue, document: document, confidence: 0.86))
        }
        if category == .documentation,
           let documentType = ["电子发票", "发票", "收据", "合同", "证明", "退款记录", "报销单", "凭证"].first(where: normalized.contains) {
            result.fields.append(field(.documentType, documentType, document: document, confidence: 0.84))
        }
        if let reference = capture("(?:发票号码|发票号|凭证编号|凭证号|单据编号|单据号|合同编号|收据编号|参考编号)[：:\\s]*([A-Za-z0-9-]+)", text) {
            result.fields.append(field(.documentReference, reference, document: document, confidence: 0.92))
        }
        if let excerpt = OCRTextExcerpt.make(from: text, excluding: result.title) {
            result.fields.append(field(.excerpt, excerpt, document: document, confidence: 0.72))
        }
        return result
    }

    private func inferIntents(text: String, category: Category) -> [IntentTag] {
        let normalized = text.lowercased()
        var intents: [IntentTag] = []
        func add(_ tag: IntentTag, when condition: Bool) {
            if condition && !intents.contains(tag) { intents.append(tag) }
        }
        add(.reviewLater, when: ["以后", "稍后", "回头", "之后", "别忘", "保存"].contains(where: normalized.contains))
        add(.purchaseCandidate, when: category == .shopping || ["想买", "对比", "购物车", "愿望"].contains(where: normalized.contains))
        add(.planning, when: category == .place || category == .event || ["计划", "路线", "行程"].contains(where: normalized.contains))
        add(.evidence, when: category == .payment || category == .documentation || ["证明", "报销", "纠纷"].contains(where: normalized.contains))
        add(.share, when: ["转发", "分享", "发给"].contains(where: normalized.contains))
        add(.offline, when: ["离线", "无网络", "没有网络"].contains(where: normalized.contains))
        add(.favorite, when: ["收藏", "喜欢", "推荐"].contains(where: normalized.contains))
        add(.memory, when: ["纪念", "回忆", "生日", "开心"].contains(where: normalized.contains))
        return intents
    }

    private func field(_ kind: FieldKind, _ value: String, document: OCRDocument, confidence: Double) -> ExtractedField {
        let source = document.blocks.filter { $0.text.localizedCaseInsensitiveContains(value) }.map(\.id)
        return ExtractedField(kind: kind, value: value, confidence: confidence, sourceBlockIDs: source)
    }

    private func capture(_ pattern: String, _ text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
