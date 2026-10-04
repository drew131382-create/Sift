import SwiftUI

enum PreviewLaunchOptions {
    @MainActor static func makeStore() -> SiftStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixtures") {
            // Explicit UI-test launch only: never writes the user's database.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftUITest-" + UUID().uuidString)
            if let repository = try? LocalRepository(directory:directory) {
                let store = SiftStore(repository:repository,resumePendingJobs:false)
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
                    try? store.save(item)
                }
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
