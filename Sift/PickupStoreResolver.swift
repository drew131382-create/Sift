import Foundation

/// Resolves only literal store spans in the pickup's own business region.
enum PickupStoreResolver {
    struct Resolution {
        var value: String?
        var sources: [Int] = []
        var evidence: [Int] = []
        var ambiguous = false
    }
    static func resolve(_ layout: LayoutAnalysis, region: Int, evidence: [Int]) -> Resolution {
        let body = layout.body(region)
        let codeBlocks = layout.candidates.filter { $0.region == region && $0.kind == "code" }.flatMap(\.sources)
        let notification = evidence + codeBlocks
        guard !notification.isEmpty else { return Resolution() }
        let labels = "(?:取餐门店|自提门店|门店名称|商家名称|餐厅名称|商户名称|门店|商家|餐厅|商户)"
        func clean(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ">＞»"))
                .replacingOccurrences(of: "^(?:闪购|自取|外卖)\\s+", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func name(_ text: String) -> Bool {
            let text = clean(text)
            return (2...70).contains(text.count) && LayoutAnalysis.matches("[\\p{Han}A-Za-z]{2}", text) &&
                !LayoutAnalysis.matches("取(?:餐|餮|餈|䬸|单|件|货)|已备好|备餐|配餐|制作|接单|请凭|您的|订单|电话|地址|联系|距离|附近|推荐|广告|优惠|支付|实付|合计|套餐|菜单|加入|下载|你好|好的|好吧|知道|收到|消息|聊天|对话|今天|明天|刚才|哈哈|[吧吗呢呀啊]$|^门店$|^商家$|^餐厅$|^微信$|^支付宝$|^美团$|^饿了么$|^淘宝$|^抖音$", text)
        }
        var labelled: [(String, [Int], [Int])] = []
        var signed: [(String, [Int], [Int])] = []
        var headers: [(String, [Int], [Int])] = []
        var named: [(String, [Int], [Int])] = []
        for i in body {
            let text = layout.blocks[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = LayoutAnalysis.spans("^" + labels + "[：: ]+(.+)$", text, group: 1).first, name(value) {
                labelled.append((clean(value), [i], [i] + evidence))
            } else if LayoutAnalysis.matches("^" + labels + "[：: ]*$", text) {
                let nearby = body.filter { $0 != i && layout.near(i, $0) && name(layout.blocks[$0].text) }
                for j in nearby { labelled.append((clean(layout.blocks[j].text), [j], [i] + evidence)) }
            }
            if let value = LayoutAnalysis.spans("^[【\\[]([^】\\]]+)[】\\]]", text, group: 1).first, name(value), LayoutAnalysis.matches("取餐|餐食|餐品|备好", layout.text(region)) {
                signed.append((clean(value), [i], [i] + evidence))
            }
            if name(text), LayoutAnalysis.matches("(?:店[）)]?|餐厅|飺厅|餐馆|饭店|咖啡馆|茶馆|猪脚饭)$", clean(text)),
               !LayoutAnalysis.matches("医院|公园|广场$", clean(text)) {
                named.append((clean(text), [i], notification))
            }
            // A notification/order header must be directly associated with pickup content.
            // No arbitrary first body sentence is promoted to a store.
            if name(text), notification.contains(where: { i < $0 && layout.near(i, $0) }),
               !LayoutAnalysis.matches("[，。！？!?：:]|通知|消息|详情|完成|成功|准备|您好|谢谢|欢迎|数量|备注|规格|咖啡[0-9]|[0-9]+份", text) {
                if LayoutAnalysis.matches("^[（(].+店[）)]$", text), let previous = body.last(where: { $0 < i }),
                   layout.near(previous, i), name(layout.blocks[previous].text),
                   !LayoutAnalysis.matches("店[）)]?$", layout.blocks[previous].text) {
                    headers.append((clean(layout.blocks[previous].text) + clean(text), [previous, i], notification))
                } else { headers.append((clean(text), [i], notification)) }
            }
        }
        var choices = !labelled.isEmpty ? labelled : !signed.isEmpty ? signed : !named.isEmpty ? named : headers
        // A split branch candidate carries the immediately preceding brand.
        if choices.count == 1, let choice = choices.first,
           LayoutAnalysis.matches("^[（(].+店[）)]$", choice.0), let i = choice.1.first,
           let previous = body.last(where: { $0 < i }), layout.near(previous, i), name(layout.blocks[previous].text) {
            choices = [(clean(layout.blocks[previous].text) + choice.0, [previous, i], choice.2)]
        }
        // A brand and its adjacent branch suffix form one name only when unique.
        if choices.count == 2 {
            let ordered = choices.sorted { $0.1[0] < $1.1[0] }
            if layout.near(ordered[0].1[0], ordered[1].1[0]),
               LayoutAnalysis.matches("^[（(].+店[）)]$", ordered[1].0),
               !LayoutAnalysis.matches("店[）)]?$", ordered[0].0) {
                choices = [(ordered[0].0 + ordered[1].0, ordered[0].1 + ordered[1].1, ordered[0].2 + ordered[1].2)]
            }
        }
        let distinct = Set(choices.map { $0.0 })
        guard distinct.count == 1, let choice = choices.first else { return Resolution(ambiguous: distinct.count > 1) }
        return Resolution(value: choice.0, sources: choice.1, evidence: Array(Set(choice.2 + choice.1)).sorted())
    }
}
