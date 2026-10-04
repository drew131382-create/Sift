import XCTest
import UIKit
@testable import Sift

final class FocusedScanTests: XCTestCase {
    private func document(_ text: String) -> OCRDocument {
        OCRDocument(rawText: text, blocks: [OCRBlock(text: text, boundingBox: .zero, confidence: 1)], recognitionLanguage: "zh-Hans", engineVersion: "fixture")
    }

    private func accepted(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> InformationItem {
        guard case .accepted(let item) = RuleExtractor().evaluate(text) else {
            XCTFail("Should accept: \(text)", file: file, line: line)
            throw LocalError.unreadableImage
        }
        return item
    }

    func testFourContentFamiliesAndAppointment() throws {
        let cases: [(String, Sift.Category)] = [
            ("取件码：A-123\n驿站名称：静安驿站", .delivery),
            ("取餐号：B057\n餐厅：咖啡店", .pickup),
            ("活动名称：音乐节\n活动时间：2026年10月2日 19:30", .event),
            ("预约成功\n科室：眼科\n就诊时间：2026年10月2日 09:30", .event),
            ("支付成功\n商户：咖啡店\n实付：￥24.00", .payment),
            ("商品名称：咖啡机\n到手价：199.00\n订单状态：待发货", .shopping),
            ("凭证类型：发票\n发票号码：INV-100", .documentation),
            ("资料标题：矩阵笔记\n课程主题：线性代数", .learning),
            ("地点名称：西湖\n地址：杭州市西湖区", .place),
            ("收藏标题：海边日落\n海边像橙色画布", .inspiration),
            ("应用名称：打印机\n操作步骤：打开连接菜单", .technical)
        ]
        for (text, category) in cases { XCTAssertEqual(try accepted(text).category, category, text) }
    }

    func testUnrelatedScreenshotsAreIgnored() {
        for text in ["", "09:41\n86%\n123456", "订单号：123456", "微信\n今天吃什么？\n喜欢就收藏", "设置\n安装\n错误", "快递真慢", "健康\n检查\n手机号13812345678", "https://example.com\n点击继续", "微信\n今天付款成功了", "微信\n预约成功", "微信\n你买的订单已发货了"] {
            guard case .ignored = RuleExtractor().evaluate(text) else { XCTFail("Should ignore: \(text)"); continue }
        }
        if case .accepted(let item) = RuleExtractor().evaluate("微信\n取件码：3-7-211\n驿站名称：菜鸟驿站") { XCTAssertEqual(item.code, "3-7-211") }
        else { XCTFail("Explicit pickup information in a chat should be accepted") }
    }

    func testAmbiguousAndMissingFieldsStayInReview() throws {
        let code = try accepted("取件码：A123\n取件码：B456\n手机号13812345678")
        XCTAssertEqual(code.code, "")
        XCTAssertEqual(code.state, .needsReview)
        let phone = try accepted("取件码：13812345678")
        XCTAssertEqual(phone.code, "")
        XCTAssertEqual(phone.state, .needsReview)
        let payment = try accepted("支付成功\n商户：咖啡店\n实付：80.00\n实付：90.00\n原价：100\n余额：500")
        XCTAssertEqual(payment.amount, "")
        XCTAssertEqual(payment.state, .needsReview)
        XCTAssertEqual(try accepted("支付成功\n商户：咖啡店\n实付：80\n实付：80.00").amount, "80")
        let original = try accepted("支付成功\n原价100\n优惠20\n余额500")
        XCTAssertEqual(original.amount, "")
        let event = try accepted("09:41\n活动名称：音乐节\n订单时间：2026年9月1日 10:30")
        XCTAssertFalse(event.fields.contains { [.date, .time, .eventTime].contains($0.kind) })
        XCTAssertEqual(event.state, .needsReview)
        let conflict = try accepted("活动名称：音乐节\n活动时间：2026年10月2日 19:30\n活动时间：2026年10月3日 20:30")
        XCTAssertFalse(conflict.fields.contains { [.date, .time].contains($0.kind) })
        XCTAssertEqual(conflict.state, .needsReview)
    }

    func testCutoffAndStatusFields() throws {
        let parcel = try accepted("取件码：3-7-211\n驿站名称：菜鸟驿站\n截止时间：2026年10月2日 20:00")
        XCTAssertEqual(parcel.fields.first(where: { $0.kind == .deadline })?.value, "2026年10月2日 20:00")
        XCTAssertEqual(try accepted("商品名称：咖啡机\n订单状态：待发货").fields.first(where: { $0.kind == .orderStatus })?.value, "待发货")
    }

    func testDateRangeInclusiveDaysAndValidation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        let range = ScreenshotDateRange.recent(days: 7, now: now, calendar: calendar)
        let interval = try range.interval(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: interval.start), 26)
        XCTAssertTrue(range.contains(interval.start, now: now, calendar: calendar))
        XCTAssertTrue(range.contains(interval.end.addingTimeInterval(-1), now: now, calendar: calendar))
        XCTAssertFalse(range.contains(interval.end, now: now, calendar: calendar))
        XCTAssertFalse(range.contains(nil, now: now, calendar: calendar))
        XCTAssertThrowsError(try ScreenshotDateRange(start: now, end: range.start).interval(now: now, calendar: calendar))
        XCTAssertThrowsError(try ScreenshotDateRange(start: now, end: now.addingTimeInterval(86400)).interval(now: now, calendar: calendar))
        let thirty = ScreenshotDateRange.recent(days: 30, now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: thirty.start, to: thirty.end).day, 29)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstDay = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let dst = try ScreenshotDateRange(start: dstDay, end: dstDay).interval(now: now, calendar: calendar)
        XCTAssertEqual(dst.duration, 23 * 3600)
    }

    func testScanRecordsInvalidateOnRuleOrAssetChange() {
        let asset = LocalPhotoAsset(id: "a", createdAt: Date(), modifiedAt: Date(timeIntervalSince1970: 100))
        let record = ScanRecord(assetIdentifier: "a", assetModifiedAt: asset.modifiedAt, fingerprint: "hash", ruleVersion: RuleExtractor.policyVersion, outcome: .ignored)
        XCTAssertTrue(record.matches(asset, version: RuleExtractor.policyVersion))
        XCTAssertFalse(record.matches(asset, version: "next"))
        XCTAssertFalse(record.matches(LocalPhotoAsset(id: "a", createdAt: asset.createdAt, modifiedAt: Date(timeIntervalSince1970: 101)), version: RuleExtractor.policyVersion))
    }

    @MainActor
    func testPreviewDoesNotLoadImagesAndScanIgnoresOutsideRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        let range = ScreenshotDateRange.recent(days: 7)
        let assets = [LocalPhotoAsset(id: "inside", createdAt: range.end, modifiedAt: range.end), LocalPhotoAsset(id: "outside", createdAt: range.start.addingTimeInterval(-1), modifiedAt: nil)]
        var loads: [String] = []
        var ocrCount = 0
        let store = SiftStore(repository: repository, fetchAssets: { _ in assets }, loadImage: { asset in loads.append(asset.id); return Data("普通聊天".utf8) }, recognize: { data in ocrCount += 1; return self.document(String(decoding: data, as: UTF8.self)) }, limitedAccess: { true }, extractionVersion: RuleExtractor.policyVersion, extract: { RuleExtractor().evaluate(document: $0) }, resumePendingJobs: false)
        let preview = try await store.previewScreenshots(in: range)
        XCTAssertEqual(preview.pending, 1)
        XCTAssertTrue(preview.limitedAccess)
        XCTAssertTrue(loads.isEmpty)
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(loads, ["inside"])
        XCTAssertEqual(ocrCount, 1)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(try repository.loadJobs().isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".image") })
        let records = try repository.loadScanRecords()
        XCTAssertEqual(records.first?.outcome, .ignored)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(records), as: UTF8.self).contains("普通聊天"))
        let repeated = try await store.previewScreenshots(in: range)
        XCTAssertEqual(repeated.pending, 0)
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(ocrCount, 1)
        XCTAssertEqual(store.scanReport.ignored, 1)
    }

    @MainActor
    func testManualImportUsesSameGateAndPreservesHistoricalCards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        try repository.save(InformationItem(category: .social, title: "历史聊天", rawText: "保留"))
        var count = 0
        let store = SiftStore(repository: repository, recognize: { data in count += 1; return self.document(String(decoding: data, as: UTF8.self)) }, extractionVersion: RuleExtractor.policyVersion, extract: { RuleExtractor().evaluate(document: $0) }, resumePendingJobs: false)
        let unrelated = Data("普通聊天".utf8)
        await store.importImage(unrelated)
        await store.importImage(unrelated)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.items.count, 1)
        await store.importImage(Data("取餐号：A057\n餐厅：咖啡店".utf8))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first(where: { $0.category == .pickup })?.code, "A057")
    }

    @MainActor
    func testStopFinishesCurrentImageWithoutQueuingNext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        let range = ScreenshotDateRange.recent(days: 7)
        let assets = (1...3).map { LocalPhotoAsset(id: "\($0)", createdAt: range.end, modifiedAt: nil) }
        var loads = 0
        var store: SiftStore!
        store = SiftStore(repository: repository, fetchAssets: { _ in assets }, loadImage: { asset in loads += 1; return Data("取餐号：A\(asset.id)\n餐厅：咖啡店".utf8) }, recognize: { data in store.stopScanning(); return self.document(String(decoding: data, as: UTF8.self)) }, extractionVersion: RuleExtractor.policyVersion, extract: { RuleExtractor().evaluate(document: $0) }, resumePendingJobs: false)
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.scanReport.processed, 1)
        XCTAssertTrue(try repository.loadJobs().isEmpty)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.message?.contains("已停止") == true)
    }

    @MainActor
    func testDownloadAndOCRFailuresRemainRetryable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        let range = ScreenshotDateRange.recent(days: 7)
        let asset = LocalPhotoAsset(id: "a", createdAt: range.end, modifiedAt: nil)
        var failDownload = true
        var failOCR = true
        let store = SiftStore(repository: repository, fetchAssets: { _ in [asset] }, loadImage: { _ in if failDownload { throw LocalError.unreadableImage }; return Data("取餐号：A057\n餐厅：咖啡店".utf8) }, recognize: { data in if failOCR { throw LocalError.unreadableImage }; return self.document(String(decoding: data, as: UTF8.self)) }, extractionVersion: RuleExtractor.policyVersion, extract: { RuleExtractor().evaluate(document: $0) }, resumePendingJobs: false)
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(store.scanReport.failed, 1)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(try repository.loadScanRecords().isEmpty)
        let downloadJob = try XCTUnwrap(store.jobs.first)
        XCTAssertEqual(downloadJob.imageName, "")
        failDownload = false
        await store.retry(downloadJob)
        XCTAssertEqual(store.jobs.first?.state, .failed)
        XCTAssertFalse(store.jobs.first?.imageName.isEmpty ?? true)
        XCTAssertTrue(try repository.loadScanRecords().isEmpty)
        failOCR = false
        await store.retry(try XCTUnwrap(store.jobs.first))
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertEqual(store.items.count, 1)
    }

    @MainActor
    func testRestartResumesOnlyPersistedJobsAndAppliesGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        try Data("无关聊天".utf8).write(to: directory.appendingPathComponent("queued.image"))
        try repository.save(job: ProcessingJob(imageName: "queued.image", fingerprint: "queued"))
        let finished = expectation(description: "persisted job OCR")
        var fetches = 0
        let store = SiftStore(repository: repository, fetchAssets: { _ in fetches += 1; return [] }, recognize: { data in finished.fulfill(); return self.document(String(decoding: data, as: UTF8.self)) }, extractionVersion: RuleExtractor.policyVersion, extract: { RuleExtractor().evaluate(document: $0) })
        await fulfillment(of: [finished], timeout: 5)
        // Allow the resumed task to commit its outcome after OCR returns.
        await Task.yield()
        XCTAssertEqual(fetches, 0)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(try repository.loadJobs().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("queued.image").path))
    }

    @MainActor
    func testAssetOrRuleChangesReevaluateIgnoredContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        let range = ScreenshotDateRange.recent(days: 7)
        var modified = Date(timeIntervalSince1970: 1)
        var content = "无关聊天"
        var ocrCalls = 0
        try repository.finish(jobID: UUID(), record: ScanRecord(assetIdentifier: "a", assetModifiedAt: modified, fingerprint: "old", ruleVersion: "old-rules", outcome: .ignored))
        let store = SiftStore(repository: repository, fetchAssets: { _ in [LocalPhotoAsset(id: "a", createdAt: range.end, modifiedAt: modified)] }, loadImage: { _ in Data(content.utf8) }, recognize: { data in ocrCalls += 1; return self.document(String(decoding: data, as: UTF8.self)) }, extractionVersion: RuleExtractor.policyVersion, extract: { RuleExtractor().evaluate(document: $0) }, resumePendingJobs: false)
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(ocrCalls, 1)
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(ocrCalls, 1)
        modified = Date(timeIntervalSince1970: 2)
        content = "取餐号：A057\n餐厅：咖啡店"
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(ocrCalls, 2)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(try repository.loadScanRecords().first?.outcome, .accepted)
    }

    @MainActor
    func testDuplicateAssetDoesNotReplaceFailedQueueJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        let range = ScreenshotDateRange.recent(days: 7)
        let assets = ["a", "b"].map { LocalPhotoAsset(id: $0, createdAt: range.end, modifiedAt: nil) }
        var ocrCalls = 0
        let store = SiftStore(repository: repository, fetchAssets: { _ in assets }, loadImage: { _ in Data("same".utf8) }, recognize: { _ in ocrCalls += 1; throw LocalError.unreadableImage }, extractionVersion: RuleExtractor.policyVersion, extract: { RuleExtractor().evaluate(document: $0) }, resumePendingJobs: false)
        await store.scanScreenshotAlbum(in: range)
        XCTAssertEqual(ocrCalls, 1)
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(store.jobs.first?.photoAssetIdentifier, "a")
        XCTAssertEqual(try repository.loadJobs().first?.id, store.jobs.first?.id)
        XCTAssertTrue(try repository.loadScanRecords().isEmpty)
        XCTAssertEqual(store.scanReport.failed, 1)
        XCTAssertEqual(store.scanReport.alreadyKnown, 1)
    }

    @MainActor
    func testEmptyAndInvalidRangesDoNotLoadImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(directory: directory)
        var fetches = 0
        var loads = 0
        let store = SiftStore(repository: repository, fetchAssets: { _ in fetches += 1; return [] }, loadImage: { _ in loads += 1; return Data() }, extractionVersion: RuleExtractor.policyVersion, extract: { RuleExtractor().evaluate(document: $0) }, resumePendingJobs: false)
        let range = ScreenshotDateRange.recent(days: 7)
        let preview = try await store.previewScreenshots(in: range)
        XCTAssertEqual(preview.pending, 0)
        await store.scanScreenshotAlbum(in: range)
        let countBeforeInvalid = fetches
        await store.scanScreenshotAlbum(in: ScreenshotDateRange(start: range.end, end: range.start))
        XCTAssertEqual(fetches, countBeforeInvalid)
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(store.scanReport.processed, 0)
    }

    @MainActor
    func testActualVisionOCRFeedsFocusedAdmission() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
            let text = "取餐号：A057\n餐厅：咖啡店"
            (text as NSString).draw(in: CGRect(x: 40, y: 60, width: 820, height: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
        }
        let recognized = try await LocalOCR.recognize(try XCTUnwrap(image.pngData()))
        guard case .accepted(let item) = RuleExtractor().evaluate(document: recognized) else { return XCTFail("Vision result not accepted: \(recognized.rawText)") }
        XCTAssertEqual(item.category, .pickup)
        XCTAssertEqual(item.code, "A057", recognized.rawText)
    }


    func testInvalidCalendarDateDoesNotBecomeEventDate() throws {
        let item = try accepted("活动名称：音乐节\n活动时间：2026年2月30日 19:30")
        XCTAssertFalse(item.fields.contains { $0.kind == .date })
        XCTAssertEqual(item.state, .needsReview)
        let receipt = try accepted("快递配送服务\n凭证类型：发票\n发票号码：INV-100")
        XCTAssertEqual(receipt.category, .documentation)
        XCTAssertEqual(receipt.fields.first(where: { $0.kind == .documentType })?.value, "发票")
    }

}
