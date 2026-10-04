import Foundation

enum ExtractionDecision {
    case accepted(InformationItem)
    case ignored
}

extension RuleExtractor {
    static let policyVersion = "focused-v1"

    func evaluate(_ text: String) -> ExtractionDecision {
        evaluate(document: OCRDocument(rawText: text, blocks: [OCRBlock(text: text, boundingBox: .zero, confidence: 1)], recognitionLanguage: "zh-Hans,en-US", engineVersion: Self.policyVersion))
    }

    /// Admission uses scene evidence, separately from the legacy keyword classifier.
    func evaluate(document: OCRDocument) -> ExtractionDecision {
        let text = document.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignored }
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        var item = extract(document: document)
        let chatSurface = has("(?m)^微信[ \t]*$|群聊|发送消息|聊天记录")
        let delivery = has("取件码|提货码|取货码") || (has("快递|包裹|驿站") && has("待取件|已到达|取件通知|取货地点|取件地点|自提点|代收点"))
        let pickup = has("取餐号|取餐码|取餐号码") || (has("取餐") && has("门店|餐厅|订单|请凭|等待"))
        let event = has("(?:活动名称|会议主题|活动时间|演出时间|会议时间|预约时间|预约日期|就诊时间|出发时间|航班号|车次|入住时间)[：: \\t]") || (has("(?m)^(?:预约成功|挂号成功|预约详情|电子车票|电子机票)[ \t]*$") && !chatSurface)
        let payment = has("(?:实付(?:金额)?|实际支付|支付金额)[：: \\t￥¥0-9]") || (has("(?m)^(?:支付成功|交易成功|付款成功|收款成功)[ \t]*$") && (!chatSurface || item.fields.contains { $0.kind == .merchant }))
        let documentScene = has("(?:凭证类型|发票号码|发票号|收据编号|合同编号|凭证编号)[：: \\t]") || (has("发票|收据|报销单|合同|凭证") && has("金额|编号|日期|购方|购买方"))
        let shopping = has("(?:商品名称|商品名|产品名称)[：: \\t]") || (has("订单|购物车") && has("待付款|待发货|已发货|已完成|已取消|交易关闭|订单状态|实付|到手价|[¥￥][ \t]*[0-9]+") && (!chatSurface || has("(?:订单状态|商品|商户)[：: \\t]")))
        let place = has("(?:地点名称|景点名称|目的地|酒店名称|地址|行程路线|交通路线)[：: \\t]") && item.fields.contains { [.location, .address, .route].contains($0.kind) }
        let learning = has("(?:资料标题|笔记标题|论文标题|课程主题|课程名称|知识点)[：: \\t]") || (has("课程|讲义|论文|笔记|食谱|书单") && item.fields.contains { [.url, .topic].contains($0.kind) })
        let technical = has("操作步骤|解决方法|教程标题") && item.fields.contains { [.issueSteps, .operationTarget].contains($0.kind) }
        let inspiration = has("(?:收藏标题|内容标题|灵感标题|金句)[：: \\t]") && text.split(separator: "\n").count > 1
        let scenes: [(Category, Bool)] = [(.delivery, delivery), (.pickup, pickup), (.event, event), (.documentation, documentScene), (.payment, payment), (.shopping, shopping), (.place, place), (.learning, learning), (.technical, technical), (.inspiration, inspiration)]
        guard let category = scenes.first(where: { $0.1 })?.0 else { return .ignored }
        item.category = category
        item.classificationVersion = Self.policyVersion
        item.classificationConfidence = 0.9
        item.matchedKeywords = ["取件码", "取货码", "提货码", "取餐号", "取餐码", "预约成功", "就诊时间", "活动名称", "活动时间", "支付成功", "实付", "商品名称", "订单状态", "发票", "收据", "地址", "资料标题", "课程主题", "操作步骤", "收藏标题"].filter { text.contains($0) }
        item.intents = category == .event || category == .place ? [.planning] : category == .payment || category == .documentation ? [.evidence] : category == .shopping ? [.purchaseCandidate] : [.reviewLater]

        let allowed: Set<FieldKind>
        switch category {
        case .delivery: allowed = [.parcelStation, .address, .location, .contact]
        case .pickup: allowed = [.venue, .merchant, .address, .location]
        case .event: allowed = [.eventName, .location, .address, .route, .contact]
        case .payment: allowed = [.merchant, .product, .documentReference]
        case .shopping: allowed = [.product, .merchant, .price]
        case .documentation: allowed = [.documentType, .documentReference, .merchant]
        case .place: allowed = [.location, .address, .route, .venue]
        case .learning: allowed = [.topic]
        case .technical: allowed = [.operationTarget, .issueSteps]
        case .inspiration: allowed = []
        default: allowed = []
        }
        item.fields.removeAll { !allowed.union([.url, .excerpt]).contains($0.kind) }
        item.code = ""
        item.amount = ""
        var uncertain = false
        func addUnique(_ kind: FieldKind, values: [String]) {
            let unique = Array(Set(values.filter { !$0.isEmpty }))
            guard unique.count <= 1 else { uncertain = true; return }
            guard let value = unique.first else { return }
            let sources = document.blocks.filter { $0.text.contains(value) }.map(\.id)
            item.fields.append(ExtractedField(kind: kind, value: value, confidence: 0.95, sourceBlockIDs: sources))
        }
        if category == .delivery || category == .pickup {
            let labels = category == .delivery ? "取件码|提货码|取货码" : "取餐号码|取餐号|取餐码"
            let codes = policyCaptures("(?:\(labels))[：:\\s]*([A-Za-z0-9]+(?:[-－][A-Za-z0-9]+)*)", text).filter {
                $0.count <= 20 && $0.rangeOfCharacter(from: .decimalDigits) != nil && $0.range(of: "^1[3-9][0-9]{9}$", options: .regularExpression) == nil
            }.map { $0.replacingOccurrences(of: "－", with: "-") }
            addUnique(.code, values: codes)
            item.code = item.fields.first(where: { $0.kind == .code })?.value ?? ""
        }
        if [.payment, .shopping, .documentation].contains(category) {
            let amounts = policyCaptures("(?:实付(?:金额)?|实际支付|支付金额)[：:\\s]*[¥￥]?\\s*([0-9]+(?:\\.[0-9]{1,2})?)(?![0-9.])", text)
            // Compare numerically so 80 and 80.00 are the same candidate.
            let normalized = Set(amounts.compactMap { Decimal(string: $0) })
            if normalized.count > 1 { uncertain = true } else { addUnique(.amount, values: Array(amounts.prefix(1))) }
            item.amount = item.fields.first(where: { $0.kind == .amount })?.value ?? ""
            addUnique(.orderStatus, values: policyCaptures("(?:订单状态[：:\\s]*)?(待付款|待发货|待取餐|待取件|已发货|已完成|已取消|交易关闭|支付成功|交易成功|退款成功)", text))
            let prices = policyCaptures("(?:商品价格|到手价|现价|售价|优惠价|单价)[：:\\s]*[¥￥]?\\s*([0-9]+(?:\\.[0-9]{1,2})?)(?![0-9.])", text)
            if Set(prices.compactMap { Decimal(string: $0) }).count > 1 {
                item.fields.removeAll { $0.kind == .price }; uncertain = true
            }
        }

        let datePattern = "(?:20[0-9]{2}[-/.年])?[0-9]{1,2}[-/.月][0-9]{1,2}日?(?![0-9])"
        let timePattern = "(?:[01]?[0-9]|2[0-3])[:：][0-5][0-9]"
        let temporalPattern = "(\(datePattern)(?:[，, \\t]*\(timePattern))?|\(timePattern))"
        if category == .event {
            let values = policyCaptures("(?:活动时间|演出时间|会议时间|预约时间|就诊时间|出发时间|入住时间|活动日期|预约日期|就诊日期|出发日期)[：:\\s]*\(temporalPattern)", text)
            let dates = Set(values.flatMap { policyCaptures("(\(datePattern))", $0) })
            let times = Set(values.flatMap { policyCaptures("(\(timePattern))", $0) }.map { $0.replacingOccurrences(of: "：", with: ":") })
            let validDates = dates.filter { validPolicyDate($0) }
            if validDates.count != dates.count { uncertain = true }
            if dates.count > 1 || times.count > 1 { uncertain = true }
            else { addUnique(.date, values: Array(validDates)); addUnique(.time, values: Array(times)) }
            if !item.fields.contains(where: { $0.kind == .eventName }) {
                addUnique(.eventName, values: policyCaptures("(?:预约项目|就诊科室|科室|航班号|车次|日程名称)[：:\\s]*([^\\n，,]+)", text))
            }
        }
        if [.delivery, .pickup, .shopping, .payment].contains(category) {
            let values = policyCaptures("(?:截止时间|取件截止|取餐截止|最晚取件|有效期至)[：:\\s]*\(temporalPattern)", text)
            let valid = values.filter { value in policyCaptures("(\(datePattern))", value).allSatisfy { validPolicyDate($0) } }
            if valid.count != values.count { uncertain = true }
            addUnique(.deadline, values: valid)
        }
        if category == .documentation {
            let dates = policyCaptures("(?:开票日期|交易日期|凭证日期|签订日期)[：:\\s]*(\(datePattern))", text)
            let valid = dates.filter { validPolicyDate($0) }
            if valid.count != dates.count { uncertain = true }
            addUnique(.date, values: valid)
            if !item.fields.contains(where: { $0.kind == .documentType }), let type = ["电子发票", "发票", "收据", "合同", "证明", "报销单", "凭证"].first(where: { text.contains($0) }) {
                addUnique(.documentType, values: [type])
            }
        }
        let important: [FieldKind]
        switch category {
        case .delivery: important = [.code, .parcelStation]
        case .pickup: important = [.code, .venue]
        case .event: important = [.eventName, .date, .time]
        case .payment: important = [.merchant, .amount]
        case .shopping: important = [.product, .price]
        case .documentation: important = [.documentType, .documentReference]
        case .place: important = [.location, .address]
        case .learning: important = [.topic]
        case .technical: important = [.issueSteps]
        default: important = [.excerpt]
        }
        let missing = important.contains { kind in !item.fields.contains(where: { $0.kind == kind && !$0.value.isEmpty }) }
        // Distinct action scenes in the same image require confirmation.
        let actionFamilies = Set(scenes.filter(\.1).compactMap { pair -> String? in
            switch pair.0 {
            case .delivery, .pickup: return "pickup"
            case .event: return "event"
            case .payment, .shopping, .documentation: return "transaction"
            default: return nil
            }
        })
        item.state = missing || uncertain || actionFamilies.count > 1 ? .needsReview : .pending
        if item.state == .needsReview { item.classificationConfidence = 0.7 }
        return .accepted(item)
    }

    private func validPolicyDate(_ value: String) -> Bool {
        let parts = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return false }
        // A placeholder leap year validates month/day without inventing a year in the output.
        let year = parts.count == 3 ? parts[0] : 2000
        let month = parts[parts.count - 2]
        let day = parts[parts.count - 1]
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == year && actual.month == month && actual.day == day
    }

    private func policyCaptures(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
