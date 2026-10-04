import Foundation

/// Admission is separate from field completeness. Missing fields can require
/// review only after the OCR contains evidence of an actual arrangement.
enum ScheduleAdmission {
    private static let action = "会议|开会|例会|面试|培训|复诊|就诊|看诊|体检|接种|疫苗|手术|诊疗|挂号|门诊|课程|上课|考试|报到|办证|签证|看房|理发|美容|读书会|音乐会|演唱会|电影|车次|列车|高铁|航班|机票|车票|酒店|入住|乘车|出发"
    private static let medical = "复诊|就诊|看诊|体检|接种|疫苗|手术|诊疗|挂号|门诊"
    private static let travel = "车次|列车|高铁|航班|机票|车票|酒店|入住|乘车|出发|起飞"
    private static let reservation = "预约(?:已)?(?:成功|确认)|预约已确认|挂号成功|预[订定](?:已)?(?:成功|确认)|预约详情|预约记录|就诊信息|门诊预约|预约项目"
    private static let itinerary = "已出票|出票成功|电子客票|电子车票|电子机票|已购票|预[订定]已确认|预[订定]成功|入住确认|酒店预订详情|航班行程|列车行程"
    private static let directive = "定在|定于|已确定|已确认|确定为|安排在|请.{0,24}(?:参加|到场|出席|前往|准时|报到)|(?:会议|例会|面试|培训|考试|上课|报到)(?:通知|安排)|通知[：:]"
    private static let reference = "新闻|报道|记者|据悉|消息称|发表于|发布于|发布时间|文章|攻略|教程|如何|示例|模板|海报|活动预告|公开活动|欢迎报名|欢迎参加|售票|营业时间|开放时间|时刻表"
    private static let uncertain = "[？?]|(?:吗|么|是否|要不要|能不能|可不可以|有没有|什么时候|几点)(?:[，,。！!]|$)|时间待定|待确认|尚未确认|暂未确认|未确定|暂定|拟定|拟于|可能|也许|打算|考虑|想去|希望|计划.{0,16}(?:去|旅游|出行|开会|预约)|准备.{0,16}(?:去|旅游|出行|开会|预约)"
    private static let cancelled = "(?:取消|失败|未成功|未预约|未预订|未出票|已退票|退订|不再举行|不开会|不用参加|无需参加)"
    private static let timeLabel = "就诊时间|复诊时间|预约时间|预约日期|会议时间|面试时间|培训时间|考试时间|报到时间|出发时间|乘车时间|发车时间|起飞时间|入住时间|入住日期|离店日期|行程日期|日期|时间"
    private static let forbiddenTimeLabel = "订单创建时间|订单支付时间|订单时间|下单时间|创建时间|支付时间|付款时间|消息时间|发送时间|聊天时间|发布时间|发表时间|发布于|发表于|更新于|更新时间|营业时间|开放时间|营业日期|开放日期|发布日期|发送日期|更新日期"

    /// Restrict citations after semantic classification, not before it. A match
    /// only makes a block eligible as evidence; evaluate still decides admission.
    static func canSupport(_ kind: ScheduleEvidence.Kind, text: String) -> Bool {
        switch kind {
        case .confirmedReservation: return has(reservation + "|" + medical, text)
        case .confirmedTravel: return has(itinerary, text)
        case .explicitNotice: return has(action, text) && (has(directive, text) || hasDate(text))
        default: return true
        }
    }

    static func canNameEvent(_ text: String) -> Bool {
        guard !text.isEmpty, !has("^(?:微信|群聊|聊天记录|预约详情|预约成功|预约已确认|预订成功|预订已确认|已出票|出票成功|电子车票|电子机票|电子客票|通知|详情|日期|时间)$", compact(text)),
              !has("^(?:酒店|航班|车票|机票|门诊)?(?:预[订定]|预约)(?:已)?(?:成功|确认)$", compact(text)),
              !has(uncertain, text), !has(cancelled, text), !has(reference, text),
              !has("^https?://|^(?:" + forbiddenTimeLabel + "|" + timeLabel + ")[：:]", text) else { return false }
        if has(action, text) { return true }
        return !hasDate(text) && !hasClock(text) && !has("医院$|诊所$|车站$|虹桥站$|科室[：:]", text)
    }

    static func eventNameLiterals(_ text: String) -> [String] {
        let names = splitClauses(text).filter(canNameEvent)
        let subjects = names.filter { has(action, $0) }
        return (subjects.isEmpty ? names : subjects).map { part in
            for separator in ["：", ":"] {
                if let range = part.range(of: separator) {
                    let suffix = part[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if canNameEvent(suffix) { return suffix }
                }
            }
            return part
        }
    }

    static func locationLiterals(_ text: String) -> [String] {
        // Optional locations must come from a place-bearing span, not a copied
        // few-shot hospital, a message question, or a time-only block.
        let labels = "地点|地址|位置|会场|诊室|医院|酒店名称|酒店|门店|场所|出发地|目的地|路线"
        if let values = captured("^(?:" + labels + ")[：:]\\s*(.+)$", text), let value = values.first,
           !has(uncertain, value), !hasClock(value) { return [value] }
        guard !has(uncertain, text), !has(cancelled, text), !has(reservation + "|" + itinerary, text), !hasDate(text), !hasClock(text),
              has("医院|诊所|门诊部|酒店|宾馆|会议室|诊室|教室|办公室|园区|大厦|公园|车站|机场|码头|[站馆楼路街巷号]$|[→↔]", text) else { return [] }
        return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    struct Context {
        fileprivate var indices: Set<Int>
        fileprivate var anchors: [Int]
        fileprivate var structured: Bool
        fileprivate var chat: Bool
        var requiresReview: Bool

        /// Check labelled times even when the small model returned only one of
        /// two conflicting values. Distinct start/end roles remain independent.
        func hasTimeConflict(blocks: [OCRBlock]) -> Bool {
            let labels = "就诊时间|复诊时间|预约时间|会议时间|面试时间|培训时间|考试时间|出发时间|乘车时间|发车时间|起飞时间|入住时间"
            var dates: [String: Set<String>] = [:], clocks: [String: Set<String>] = [:]
            guard let regex = try? NSRegularExpression(pattern: labels) else { return false }
            for index in indices.sorted() {
                let text = compact(blocks[index].text)
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range, in: text) else { continue }
                    let label = String(text[range])
                    let role = ["就诊时间", "复诊时间", "预约时间"].contains(label) ? "预约" : label
                    var suffix = String(text[range.upperBound...])
                    if suffix.trimmingCharacters(in: CharacterSet(charactersIn: "：:")).isEmpty,
                       indices.contains(index + 1), nearby(index, index + 1, blocks: blocks) {
                        suffix = compact(blocks[index + 1].text)
                    }
                    guard let value = splitClauses(suffix).first else { continue }
                    if let date = captured("(?:[0-9]{4}[年/.-])?([0-9]{1,2})[月/.-]([0-9]{1,2})日?", value), date.count == 2 {
                        dates[role, default: []].insert("\(Int(date[0]) ?? 0)/\(Int(date[1]) ?? 0)")
                    } else if let date = captured("(今天|明天|后天|昨天|前天|(?:下|本)?周[一二三四五六日天])", value)?.first {
                        dates[role, default: []].insert(date)
                    }
                    if let clock = captured("([0-2]?[0-9])[:：]([0-5][0-9])", value), clock.count == 2 {
                        clocks[role, default: []].insert("\(Int(clock[0]) ?? 0):\(Int(clock[1]) ?? 0)")
                    } else if let clock = captured("(上午|下午|晚上|中午)?([一二三四五六七八九十两0-9]+)(?:点|时)(半)?", value), clock.count == 3,
                              var hour = chineseNumber(clock[1]) {
                        if ["下午", "晚上", "中午"].contains(clock[0]), hour < 12 { hour += 12 }
                        clocks[role, default: []].insert("\(hour):\(clock[2] == "半" ? 30 : 0)")
                    }
                }
            }
            return dates.values.contains { $0.count > 1 } || clocks.values.contains { $0.count > 1 }
        }

        func permits(_ kind: FieldKind, value: String, sources: [Int], blocks: [OCRBlock]) -> Bool {
            guard [.eventName, .eventTime, .date, .time, .location, .address, .route, .venue].contains(kind) else { return true }
            let literal = sources.filter { !SemanticValidator.isStatus(blocks[$0]) && compact(blocks[$0].text).contains(compact(value)) }
            guard !literal.isEmpty, literal.allSatisfy({ indices.contains($0) }) else { return false }
            if kind == .eventName {
                guard canNameEvent(value) else { return false }
                return literal.contains { index in
                    let text = clause(containing: value, in: blocks[index].text)
                    return !has(uncertain, text) && !has(reference, text) && !has(cancelled, text)
                }
            }
            guard [.eventTime, .date, .time].contains(kind) else { return true }
            return literal.contains { index in
                let text = blocks[index].text
                guard !forbiddenTime(value, in: text) else { return false }
                let previous = index > 0 && indices.contains(index - 1) && nearby(index, index - 1, blocks: blocks) ? blocks[index - 1].text : ""
                // OCR often separates the label and its value into two blocks.
                if labelOnly(previous, pattern: forbiddenTimeLabel) { return false }
                let labelled = has(timeLabel, clause(containing: value, in: text)) || labelOnly(previous, pattern: timeLabel)
                let ownAction = has(action, clause(containing: value, in: text))
                // Standalone timestamps in a chat are not appointment times.
                if chat && bareTimestamp(value) && !labelled && !ownAction { return false }
                return labelled || ownAction || structured || ((!chat || !bareTimestamp(value)) && anchors.contains { nearby($0, index, blocks: blocks) })
            }
        }
    }

    static func evaluate(_ scene: SemanticScene, blocks: [OCRBlock]) throws -> Context? {
        guard let proof = scene.scheduleEvidence, !proof.sources.isEmpty, proof.sources.count <= 8,
              Set(proof.sources).count == proof.sources.count,
              proof.sources.allSatisfy({ blocks.indices.contains($0) }) else { throw SemanticError.invalidOutput }
        guard [.confirmedReservation, .confirmedTravel, .explicitNotice].contains(proof.kind) else { return nil }
        let chat = blocks.contains { has("^(?:微信|群聊|聊天记录)$|发送消息", $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var contexts: [Context] = []
        for anchor in proof.sources where !SemanticValidator.isStatus(blocks[anchor]) {
            let local = Set(blocks.indices.filter { nearby(anchor, $0, blocks: blocks) && !SemanticValidator.isStatus(blocks[$0]) })
            let text = local.sorted().map { blocks[$0].text }.joined(separator: "\n")
            let anchorText = blocks[anchor].text
            let clauses = splitClauses(anchorText)
            let names = scene.fields.filter { $0.kind == FieldKind.eventName.rawValue }.compactMap(\.value).filter { !$0.isEmpty }
            // Names are only useful for binding a cancellation to the same subject;
            // their existence or a generated title never proves an arrangement.
            let literalNames = names.filter { compact(text).contains(compact($0)) }
            let anchorIsReference = clauses.contains { has(reference, $0) && (has(action, $0) || has(reservation, $0) || has(itinerary, $0)) }
            if anchorIsReference { continue }
            let positive: Bool
            var structured = false
            switch proof.kind {
            case .confirmedReservation:
                let confirmed = clauses.contains { has(reservation, $0) && !has(uncertain, $0) && !has(cancelled, $0) }
                // A concrete clinic notice can omit the words "预约成功".
                let dated = local.contains { index in
                    splitClauses(blocks[index].text).contains { part in
                        hasDate(part) && hasClock(part) && !has(reference, part) && !has(forbiddenTimeLabel, part) && !has(uncertain, part)
                    }
                }
                let implicit = has(medical, anchorText) && dated
                    && has("医院|门诊部|诊所|科室[：:]|医生[：:]|诊室[：:]", text)
                    && !has(uncertain, anchorText) && !has(cancelled, anchorText)
                let specific = local.contains { index in
                    splitClauses(blocks[index].text).contains { part in
                        has(action + "|科室[：:]|预约项目[：:]|活动名称[：:]", part) && !has(reference, part) && !has(uncertain, part)
                    }
                }
                positive = (confirmed && specific) || implicit
                structured = true
            case .confirmedTravel:
                positive = clauses.contains { has(itinerary, $0) && !has(uncertain, $0) && !has(cancelled, $0) } && has(travel, text)
                structured = true
            case .explicitNotice:
                if has("海报|活动预告|公开活动|欢迎报名|欢迎参加|时刻表|营业时间|开放时间|新闻|报道|记者|据悉", text) { continue }
                positive = clauses.contains { part in
                    guard !has(uncertain, part), !has(cancelled, part), !has(reference, part) else { return false }
                    return (has(directive, part) && has(action, part))
                        || (hasDate(part) && has("开会|参加(?:会议|培训|考试)|到.{0,8}(?:开会|面试|报到)|进行(?:面试|培训|考试)|上课", part))
                        || (has("^(?:会议|面试|培训|考试|报到)通知[：:]?$", compact(part)) && has(action, text))
                }
            default: positive = false
            }
            guard positive else { continue }
            // Only inspect nearby clauses referring to this schedule. A question
            // about documents, or the cancellation of another subject, is harmless.
            let subject = proof.kind == .confirmedTravel ? travel : proof.kind == .confirmedReservation ? medical + "|预约|挂号|预订" : action
            let families = actionFamilies(anchorText + "\n" + literalNames.joined(separator: "\n"))
            let contradicted = local.contains { index in
                splitClauses(blocks[index].text).contains { part in
                    let otherFamilies = actionFamilies(part)
                    if !families.isEmpty, !otherFamilies.isEmpty, families.isDisjoint(with: otherFamilies) { return false }
                    let refers = has(subject, part) || literalNames.contains { compact(part).contains(compact($0)) }
                    guard refers else { return false }
                    // A separate dated event is not this event's cancellation.
                    if disjointDates(part, anchorText) { return false }
                    // Status or confirmation questions may live in another block.
                    // Questions about preparation do not undo an existing booking.
                    let preparation = has("带什么|要带|材料|证件|停车|入口|注意事项", part) && !hasDate(part)
                    return cancellationStatement(part) || (has(uncertain, part) && !preparation)
                }
            }
            guard !contradicted else { continue }
            contexts.append(Context(indices: local, anchors: [anchor], structured: structured, chat: chat, requiresReview: blocks[anchor].confidence < 0.65))
        }
        guard var result = contexts.first else { return nil }
        for context in contexts.dropFirst() {
            result.indices.formUnion(context.indices)
            result.anchors += context.anchors
            result.structured = result.structured || context.structured
            result.requiresReview = result.requiresReview || context.requiresReview
        }
        return result
    }

    private static func nearby(_ a: Int, _ b: Int, blocks: [OCRBlock]) -> Bool {
        if a == b { return true }
        guard abs(a - b) <= 4 else { return false }
        let left = blocks[a].boundingBox, right = blocks[b].boundingBox
        if left == .zero || right == .zero { return true }
        let overlap = min(left.maxX, right.maxX) - max(left.minX, right.minX)
        let distance = abs(left.midY - right.midY)
        return distance <= 0.03 || (distance <= 0.40 && overlap > 0)
    }

    private static func forbiddenTime(_ value: String, in text: String) -> Bool {
        if has(forbiddenTimeLabel, value) { return true }
        let plain = compact(text), target = compact(value)
        guard let range = plain.range(of: target) else { return true }
        let prefix = String(plain[..<range.lowerBound])
        guard let expression = try? NSRegularExpression(pattern: forbiddenTimeLabel + "|" + timeLabel) else { return true }
        let matches = expression.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
        guard let last = matches.last, let labelRange = Range(last.range, in: prefix) else { return false }
        return has("^(?:" + forbiddenTimeLabel + ")$", String(prefix[labelRange]))
    }

    private static func labelOnly(_ text: String, pattern: String) -> Bool { has("^(?:" + pattern + ")[：:]?$", compact(text)) }
    private static func bareTimestamp(_ value: String) -> Bool {
        has("^(?:[0-9]{4}[年/.-][0-9]{1,2}[月/.-][0-9]{1,2}日?|[0-9]{1,2}月[0-9]{1,2}日)?[0-9]{1,2}[:：][0-9]{2}$", compact(value))
    }
    private static func hasDate(_ text: String) -> Bool { has("(?<![0-9])(?:[0-9]{4}[年/.-])?(?:0?[1-9]|1[0-2])[月/.-](?:0?[1-9]|[12][0-9]|3[01])日?(?![0-9])|今天|明天|后天|昨天|前天|(?:下|本)?周[一二三四五六日天]|星期[一二三四五六日天]", text) }
    private static func hasClock(_ text: String) -> Bool { has("[0-9]{1,2}[:：][0-9]{2}|[一二三四五六七八九十两0-9]+(?:点|时)|上午|下午|晚上", text) }
    private static func disjointDates(_ a: String, _ b: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "[0-9]{1,2}月[0-9]{1,2}日|今天|明天|后天|昨天|前天|周[一二三四五六日天]") else { return false }
        func dates(_ text: String) -> Set<String> {
            Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
        }
        let left = dates(a), right = dates(b)
        return !left.isEmpty && !right.isEmpty && left.isDisjoint(with: right)
    }
    private static func clause(containing value: String, in text: String) -> String {
        splitClauses(text).first { compact($0).contains(compact(value)) } ?? text
    }
    private static func splitClauses(_ text: String) -> [String] {
        // Preserve question punctuation in the clause that it modifies.
        text.replacingOccurrences(of: "？", with: "？\n").replacingOccurrences(of: "?", with: "?\n")
            .components(separatedBy: CharacterSet(charactersIn: "\n。；;！!，,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static func cancellationStatement(_ text: String) -> Bool {
        // Detail pages often offer a cancellation action. Its label is not a
        // statement that cancellation has already happened.
        if has("^(?:取消预约|取消预订|取消行程|退订|退票|取消)(?:按钮)?$", compact(text)) { return false }
        return has(cancelled, text)
    }
    private static func captured(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func chineseNumber(_ text: String) -> Int? {
        if let numeric = Int(text) { return numeric }
        let digits = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if let digit = digits[text] { return digit }
        let parts = text.components(separatedBy: "十")
        guard parts.count == 2 else { return nil }
        let tens = parts[0].isEmpty ? 1 : digits[parts[0]]
        let ones = parts[1].isEmpty ? 0 : digits[parts[1]]
        guard let tens, let ones else { return nil }
        return tens * 10 + ones
    }
    private static func actionFamilies(_ text: String) -> Set<Int> {
        let patterns = ["会议|开会|例会", "面试", "培训|课程|上课", medical, "考试|报到", "列车|高铁|车次|车票|乘车", "航班|机票|起飞", "酒店|入住", "理发|美容", "办证|签证", "读书会", "音乐会|演唱会|电影", "看房"]
        return Set(patterns.indices.filter { has(patterns[$0], text) })
    }
    private static func has(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
}
