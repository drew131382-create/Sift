import Foundation
import EventKit
import Photos
import SQLite3
import UIKit
import UserNotifications
import Vision

enum LocalError: LocalizedError {
    case storage(String)
    case unreadableImage
    case photoAccessDenied
    case screenshotAlbumUnavailable
    case imageNotLocal

    var errorDescription: String? {
        switch self {
        case .storage(let message): return "本地存储失败：\(message)"
        case .unreadableImage: return "无法读取这张图片，请重新选择。"
        case .photoAccessDenied: return "没有照片读取权限，请在系统设置中允许 Sift 访问照片。"
        case .screenshotAlbumUnavailable: return "没有找到系统截图相簿。"
        case .imageNotLocal: return "图片尚未保存在本机，请先在系统相册下载，再重试。"
        }
    }
}

enum ProcessingJobState: String, Codable, CaseIterable {
    case queued
    case loadingImage
    case recognizingText
    case extractingFields
    case needsReview
    case completed
    case failed

    var displayName: String {
        switch self {
        case .queued: return "等待处理"
        case .loadingImage: return "读取图片"
        case .recognizingText: return "本地识别文字"
        case .extractingFields: return "本地理解内容"
        case .needsReview: return "等待确认"
        case .completed: return "已完成"
        case .failed: return "处理失败"
        }
    }
}

struct ProcessingJob: Codable, Identifiable {
    var id = UUID()
    var imageName: String
    var fingerprint: String
    var photoAssetIdentifier: String? = nil
    var photoAssetCreatedAt: Date? = nil
    var photoAssetModifiedAt: Date? = nil
    var scanSessionID: UUID? = nil
    var state: ProcessingJobState = .queued
    var errorMessage: String?
    var createdAt = Date()
    var updatedAt = Date()
}

struct LocalPhotoAsset: Identifiable {
    let id: String
    let createdAt: Date
    let modifiedAt: Date?
}

@MainActor
enum LocalPhotoLibrary {
    static var hasLimitedAccess: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited }

    static func screenshotAssets(in range: ScreenshotDateRange) async throws -> [LocalPhotoAsset] {
        let interval = try range.interval()
        let status = await authorizationStatus()
        guard status == .authorized || status == .limited else { throw LocalError.photoAccessDenied }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", interval.start as NSDate, interval.end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets: PHFetchResult<PHAsset>
        if status == .limited {
            // Smart albums may not be available under limited access; inspect authorized metadata only.
            assets = PHAsset.fetchAssets(with: .image, options: options)
        } else {
            let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil)
            guard let collection = collections.firstObject else { throw LocalError.screenshotAlbumUnavailable }
            assets = PHAsset.fetchAssets(in: collection, options: options)
        }
        var result: [LocalPhotoAsset] = []
        assets.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image, asset.mediaSubtypes.contains(.photoScreenshot), let date = asset.creationDate else { return }
            result.append(LocalPhotoAsset(id: asset.localIdentifier, createdAt: date, modifiedAt: asset.modificationDate))
        }
        return result
    }

    static func imageData(for metadata: LocalPhotoAsset) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [metadata.id], options: nil).firstObject else { throw LocalError.unreadableImage }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = false
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                guard let data else {
                    let cloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                    continuation.resume(throwing: cloud ? LocalError.imageNotLocal : LocalError.unreadableImage)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private static func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

final class LocalRepository {
    private var db: OpaquePointer?
    private var hasFTS = false
    let directory: URL

    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sift", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Keep the encrypted local vault accessible after the first unlock, including
        // when an explicitly started continuous task runs with the screen locked.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: self.directory.path)
        for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        guard sqlite3_open(self.directory.appendingPathComponent("sift.sqlite").path, &db) == SQLITE_OK else {
            throw LocalError.storage("无法打开数据库")
        }
        try execute("PRAGMA user_version = 4")
        try execute("CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS processing_jobs (id TEXT PRIMARY KEY, payload BLOB NOT NULL, fingerprint TEXT UNIQUE NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS scan_records (record_key TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS scan_session (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)")
        do {
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(item_id UNINDEXED, title, raw_text, fields, category, intents)")
            hasFTS = true
        } catch {
            hasFTS = false
        }
    }

    deinit { sqlite3_close(db) }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    func save(session: ScanSession?) throws {
        guard let session else { try execute("DELETE FROM scan_session"); return }
        let data = try JSONEncoder().encode(session)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO scan_session(id,payload) VALUES(1,?)", -1, &statement, nil) == SQLITE_OK else { throw LocalError.storage("扫描进度写入准备失败") }
        defer { sqlite3_finalize(statement) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalError.storage("扫描进度写入失败") }
    }

    func loadScanSession() throws -> ScanSession? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM scan_session WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw LocalError.storage("扫描进度读取失败") }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw LocalError.storage("扫描进度读取失败") }
        let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
        return try JSONDecoder().decode(ScanSession.self, from: data)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalError.storage(String(cString: sqlite3_errmsg(db)))
        }
    }

    func load() throws -> [InformationItem] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM items", -1, &statement, nil) == SQLITE_OK else {
            throw LocalError.storage("读取失败")
        }
        defer { sqlite3_finalize(statement) }
        var items: [InformationItem] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
            items.append(try JSONDecoder().decode(InformationItem.self, from: data))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw LocalError.storage("读取中断") }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ item: InformationItem) throws {
        var savedItem = item
        if let previous = try loadItem(id: item.id) {
            savedItem.preserveUserEdits(from: previous)
        }
        let data = try JSONEncoder().encode(savedItem)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO items(id,payload) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else {
            throw LocalError.storage("写入准备失败")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = savedItem.id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalError.storage("写入失败") }
        try updateSearchIndex(for: savedItem)
    }

    private func loadItem(id: UUID) throws -> InformationItem? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM items WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw LocalError.storage("读取旧信息失败")
        }
        defer { sqlite3_finalize(statement) }
        _ = id.uuidString.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
        return try JSONDecoder().decode(InformationItem.self, from: data)
    }

    func save(job: ProcessingJob) throws {
        let data = try JSONEncoder().encode(job)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO processing_jobs(id,payload,fingerprint) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,fingerprint=excluded.fingerprint", -1, &statement, nil) == SQLITE_OK else {
            throw LocalError.storage("任务写入准备失败")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = job.id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        _ = job.fingerprint.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalError.storage("任务写入失败") }
    }

    func loadJobs() throws -> [ProcessingJob] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM processing_jobs", -1, &statement, nil) == SQLITE_OK else {
            throw LocalError.storage("任务读取失败")
        }
        defer { sqlite3_finalize(statement) }
        var jobs: [ProcessingJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
            jobs.append(try JSONDecoder().decode(ProcessingJob.self, from: data))
        }
        return jobs.sorted { $0.createdAt < $1.createdAt }
    }

    func delete(jobID: UUID) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM processing_jobs WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw LocalError.storage("任务删除准备失败")
        }
        defer { sqlite3_finalize(statement) }
        _ = jobID.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalError.storage("任务删除失败") }
    }

    func loadScanRecords() throws -> [ScanRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM scan_records", -1, &statement, nil) == SQLITE_OK else { throw LocalError.storage("读取扫描记录失败") }
        defer { sqlite3_finalize(statement) }
        var records: [ScanRecord] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
            records.append(try JSONDecoder().decode(ScanRecord.self, from: data))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw LocalError.storage("扫描记录读取中断") }
        return records
    }

    /// Record the outcome and remove its queue entry together; no OCR text is retained here.
    func finish(jobID: UUID, record: ScanRecord, session: ScanSession? = nil) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let data = try JSONEncoder().encode(record)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO scan_records(record_key,payload) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw LocalError.storage("扫描记录写入准备失败") }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = record.key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalError.storage("扫描记录写入失败") }
            try delete(jobID: jobID)
            if let session { try save(session: session) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func cleanUnreferencedImages() throws {
        let referenced = Set(try load().map(\.imageName) + loadJobs().map(\.imageName))
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "image" && !referenced.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func searchIDs(for query: String) throws -> Set<UUID>? {
        guard hasFTS, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT item_id FROM search_index WHERE search_index MATCH ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let safeQuery = query.split(whereSeparator: { $0.isWhitespace }).map { "\($0)*" }.joined(separator: " ")
        _ = safeQuery.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var ids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: pointer)) { ids.insert(id) }
        }
        return ids
    }

    private func updateSearchIndex(for item: InformationItem) throws {
        guard hasFTS else { return }
        var deleteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM search_index WHERE item_id = ?", -1, &deleteStatement, nil) == SQLITE_OK else { return }
        _ = item.id.uuidString.withCString { sqlite3_bind_text(deleteStatement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        _ = sqlite3_step(deleteStatement)
        sqlite3_finalize(deleteStatement)

        let values = [
            item.id.uuidString,
            item.title,
            item.rawText,
            ([item.code, item.amount, item.note] + item.fields.map(\.value)).joined(separator: " "),
            item.category.displayName,
            item.intents.map(\.displayName).joined(separator: " ")
        ]
        var insertStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO search_index(item_id,title,raw_text,fields,category,intents) VALUES(?,?,?,?,?,?)", -1, &insertStatement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insertStatement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            _ = value.withCString { sqlite3_bind_text(insertStatement, Int32(index + 1), $0, -1, transient) }
        }
        guard sqlite3_step(insertStatement) == SQLITE_DONE else { throw LocalError.storage("搜索索引写入失败") }
    }
}

enum LocalOCR {
    static func recognize(_ data: Data) async throws -> OCRDocument {
        try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data), let cgImage = image.cgImage else { throw LocalError.unreadableImage }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let orientations: [UIImage.Orientation: CGImagePropertyOrientation] = [.up: .up, .down: .down, .left: .left, .right: .right, .upMirrored: .upMirrored, .downMirrored: .downMirrored, .leftMirrored: .leftMirrored, .rightMirrored: .rightMirrored]
            try VNImageRequestHandler(cgImage: cgImage, orientation: orientations[image.imageOrientation] ?? .up).perform([request])
            let blocks = (request.results ?? []).compactMap { observation -> OCRBlock? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRBlock(text: candidate.string, boundingBox: observation.boundingBox, confidence: Double(candidate.confidence))
            }
            return OCRDocument(rawText: blocks.map(\.text).joined(separator: "\n"), blocks: blocks, recognitionLanguage: "zh-Hans,en-US", engineVersion: "Vision-accurate")
        }.value
    }
}

enum LocalReminders {
    static func schedule(_ item: InformationItem, at date: Date) async throws {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw LocalError.storage("通知权限未开启，请在系统设置中开启。")
        }
        let content = UNMutableNotificationContent()
        content.title = "Sift 提醒"
        content.body = "有一条你保存的信息需要处理。"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
        try await center.add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger))
    }

    static func cancel(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }
}

@MainActor
enum LocalActions {
    static func openMap(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: "http://maps.apple.com/") else { return }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    static func addToCalendar(_ item: InformationItem, at date: Date) async throws {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .fullAccess {
            guard try await store.requestFullAccessToEvents() else {
                throw LocalError.storage("日历权限未开启，请在系统设置中开启。")
            }
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw LocalError.storage("没有可用的日历。")
        }
        let event = EKEvent(eventStore: store)
        event.title = item.title
        event.notes = "由 Sift 本地创建。"
        event.startDate = date
        event.endDate = date.addingTimeInterval(3600)
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }
}
