import SwiftUI

enum PreviewLaunchOptions {
    @MainActor static func makeStore() -> SiftStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixtures") || ProcessInfo.processInfo.arguments.contains("--ui-empty-fixtures") {
            // Explicit UI-test launch only: never writes the user's database.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftUITest-" + UUID().uuidString)
            if let repository = try? LocalRepository(directory:directory) {
                let store = SiftStore(repository:repository,fetchAssets:{ _ in [] },limitedAccess:{ false },resumePendingJobs:false)
                if ProcessInfo.processInfo.arguments.contains("--ui-empty-fixtures") { return store }
                let categories: [Category] = [.delivery,.pickup,.delivery,.event,.health,.payment,.learning,.place,.other]
                let titles = ["测试驿站","测试茶店","顺丰测试点","测试预约","历史健康","测试付款","测试资料","测试地点","历史记录"]
                let image = UIGraphicsImageRenderer(size:CGSize(width:300,height:600)).image { context in
                    UIColor.systemYellow.setFill(); context.fill(CGRect(x:0,y:0,width:300,height:600))
                    ("UI测试图片" as NSString).draw(at:CGPoint(x:30,y:40),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.black])
                }
                if let data = image.pngData() { try? data.write(to:directory.appendingPathComponent("test.image")) }
                for i in categories.indices {
                    var item = InformationItem(category:categories[i],title:titles[i],rawText:"UI自动化测试数据")
                    item.id = UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",i+1))!
                    item.createdAt = Date().addingTimeInterval(-Double(i)*60); item.state = .pending
                    item.displayApproval = .userConfirmed
                    item.imageName = i == 8 ? "missing.image" : "test.image"
                    if i < 3 { item.code = "55"; item.fields = [ExtractedField(kind:.code,value:"55",confidence:1,sourceBlockIDs:[])] }
                    func field(_ kind: FieldKind, _ value: String) -> ExtractedField { .init(kind:kind,value:value,confidence:1,sourceBlockIDs:[]) }
                    switch item.category {
                    case .pickup: item.fields.append(field(.venue,titles[i]))
                    case .event: item.fields = [field(.eventName,titles[i]),field(.eventTime,"2026年10月8日 15:00")]
                    case .health: item.fields = [field(.healthItem,titles[i]),field(.date,"2026年10月8日")]
                    case .payment: item.fields = [field(.merchant,titles[i]),field(.amount,"37.66")]
                    case .learning:
                        item.fields = [field(.topic,titles[i]),field(.excerpt,"界面自动化测试的资料正文"),
                            .init(kind:.excerpt,value:"第二段互补正文",confidence:0.4,sourceBlockIDs:[])]
                        item.reprocessingReasons = [.init(kind:.conflictingRequiredField,field:.excerpt,detail:"文字摘录存在冲突")]
                    case .place: item.fields = [field(.location,titles[i]),field(.address,"测试路1号")]
                    case .other: item.fields = [field(.excerpt,"历史记录文字")]
                    default: break
                    }
                    try? store.save(item)
                }
                var incomplete = InformationItem(category:.pickup,title:"缺门店测试截图",rawText:"取餐码：A057")
                incomplete.id = UUID(uuidString:"00000000-0000-0000-0000-000000000010")!
                incomplete.fields = [.init(kind:.code,value:"A057",confidence:1,sourceBlockIDs:[])]
                incomplete.imageName = "test.image"
                try? store.save(incomplete)
                return store
            }
        }
        #endif
        return SiftStore()
    }

    static var previewScan: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--preview-scan")
        #else
        return false
        #endif
    }

    static var reduceMotion: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-fixtures") && ProcessInfo.processInfo.arguments.contains("--reduce-motion")
        #else
        return false
        #endif
    }
    static var previewTab: Int {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-settings") { return 3 }
        if ProcessInfo.processInfo.arguments.contains("--preview-review") { return 1 }
        if ProcessInfo.processInfo.arguments.contains("--preview-library") { return 2 }
        #endif
        return 0
    }
    static var previewCategory: CategoryGroup? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--preview-category"), args.indices.contains(index + 1) {
            return CategoryGroup(rawValue: args[index + 1])
        }
        #endif
        return nil
    }

}
