import XCTest
import UIKit
@testable import Sift

final class SemanticDeviceSmokeTests: XCTestCase {
    func testActualVisionAndBundledModelOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("MLX inference is verified on a physical device; simulator tests use injected extraction.")
        #else
        let cases: [(String, String?, FieldKind?, String?)] = [
            ("包裹已到静安驿站\n请凭8-3021领取包裹", "delivery", .code, "8-3021"),
            ("街角咖啡\n您的餐食已备好\n取餐号 A057", "pickup", .code, "A057"),
            ("预约详情\n牙科复诊\n就诊时间：2026年10月3日 09:30\n市口腔医院", "event", nil, nil),
            ("支付成功\n商户：街角咖啡\n原价：100.00\n优惠：20.00\n实付金额：24.00\n余额：500.00", "payment", .amount, "24.00"),
            ("SwiftUI 导航教程\n使用 NavigationStack 管理页面跳转\nhttps://developer.apple.com/documentation/swiftui/navigationstack", "technical", nil, nil),
            ("微信\n今天吃什么？\n火锅吧", nil, nil, nil),
            ("09:41\n86%\n123456", nil, nil, nil)
        ]
        var log: [String] = []
        for entry in cases {
            let data = await MainActor.run {
                UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1600)).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1600))
                    (entry.0 as NSString).draw(in: CGRect(x: 60, y: 180, width: 880, height: 1300), withAttributes: [.font: UIFont.systemFont(ofSize: 50), .foregroundColor: UIColor.black])
                }.pngData()!
            }
            let document = try await LocalOCR.recognize(data)
            let start = Date()
            let decision = try await LocalModelEngine.shared.evaluate(document: document)
            switch decision {
            case .ignored:
                XCTAssertNil(entry.1, document.rawText)
                log.append("ignored \(Date().timeIntervalSince(start))s OCR=\(document.rawText)")
            case .accepted(let item):
                XCTAssertEqual(item.category.rawValue, entry.1, document.rawText)
                if let kind = entry.2 { XCTAssertEqual(item.fields.first(where: { $0.kind == kind })?.value, entry.3, document.rawText) }
                log.append("\(item.category.rawValue) \(item.state.rawValue) \(Date().timeIntervalSince(start))s fields=\(item.fields.map { $0.kind.rawValue + "=" + $0.value })")
            }
        }
        log.append("MLX peak bytes=\(await LocalModelEngine.shared.peakModelMemory)")
        let attachment = XCTAttachment(string: log.joined(separator: "\n")); attachment.name = "真机合成截图与本地模型结果（非真实样本准确率）"; attachment.lifetime = .keepAlways; add(attachment)
        await LocalModelEngine.shared.release()
        #endif
    }
}
