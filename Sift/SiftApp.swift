import SwiftUI
import PhotosUI
import CryptoKit
import ImageIO

@MainActor
final class SiftStore: ObservableObject {
    @Published var items: [InformationItem] = []
    @Published var jobs: [ProcessingJob] = []
    @Published var busy = false
    @Published var scanningScreenshots = false
    @Published var scanReport = ScanReport()
    @Published var scanTotal = 0
    @Published var stopRequested = false
    @Published var scanSuspended = false
    @Published var backgroundScanStatus: String?
    @Published var message: String?
    private var repository: LocalRepository?
    private var records: [String: ScanRecord] = [:]
    private var operationRunning = false
    private let fetchAssets: @MainActor (ScreenshotDateRange) async throws -> [LocalPhotoAsset]
    private let loadImage: @MainActor (LocalPhotoAsset) async throws -> Data
    private let recognize: @MainActor (Data) async throws -> OCRDocument
    private let limitedAccess: @MainActor () -> Bool
    private let extract: @MainActor (OCRDocument) async throws -> ExtractionDecision
    private let extractionVersion: String
    private var paused = false
    private var foreground = true
    private var scanSession: ScanSession?
    private let backgroundScan = BackgroundScan()
    private let thumbnails = NSCache<NSString, UIImage>()

    init(repository: LocalRepository? = nil,
         fetchAssets: @escaping @MainActor (ScreenshotDateRange) async throws -> [LocalPhotoAsset] = { try await LocalPhotoLibrary.screenshotAssets(in: $0) },
         loadImage: @escaping @MainActor (LocalPhotoAsset) async throws -> Data = { try await LocalPhotoLibrary.imageData(for: $0) },
         recognize: @escaping @MainActor (Data) async throws -> OCRDocument = { try await LocalOCR.recognize($0) },
         limitedAccess: @escaping @MainActor () -> Bool = { LocalPhotoLibrary.hasLimitedAccess },
         extractionVersion: String = SemanticPolicy.version,
         extract: @escaping @MainActor (OCRDocument) async throws -> ExtractionDecision = { try await LocalModelEngine.shared.evaluate(document: $0) },
         resumePendingJobs: Bool = true) {
        self.fetchAssets = fetchAssets
        self.loadImage = loadImage
        self.recognize = recognize
        self.limitedAccess = limitedAccess
        self.extract = extract
        self.extractionVersion = extractionVersion
        thumbnails.totalCostLimit = 24 * 1024 * 1024
        do {
            self.repository = try repository ?? LocalRepository()
            items = try self.repository!.load().map { var item = $0; item.requireReviewBeforeDisplay(); return item }
            jobs = try self.repository!.loadJobs()
            scanSession = try self.repository!.loadScanSession()
            if var session = scanSession {
                // A terminated app must not silently acquire a new system grant.
                session.requiresResume = true
                scanSession = session
                try self.repository!.save(session: session)
                scanReport = session.report
                scanTotal = session.total
                scanSuspended = true
            }
            records = Dictionary(uniqueKeysWithValues: try self.repository!.loadScanRecords().map { ($0.key, $0) })
            try? self.repository!.cleanUnreferencedImages()
            if resumePendingJobs && scanSession?.requiresResume != true && jobs.contains(where: { $0.state != .failed }) {
                busy = true
                Task { await resumeJobs() }
            }
        } catch { message = error.localizedDescription }
    }

    func save(_ item: InformationItem) throws {
        guard let repository else { throw LocalError.storage("数据库不可用") }
        var stored = item
        stored.requireReviewBeforeDisplay()
        try repository.save(stored)
        items = try repository.load().map { var item = $0; item.requireReviewBeforeDisplay(); return item }
    }

    var dataDirectory: URL? { repository?.directory }
    var canScanInBackground: Bool { backgroundScan.isGranted }

    func clearUnusedFiles() async throws {
        guard let repository else { throw LocalError.storage("数据库不可用") }
        guard !operationRunning, !busy else { throw LocalError.storage("请等当前识别结束后再清理") }
        operationRunning = true
        busy = true
        defer { finishOperation() }
        thumbnails.removeAllObjects()
        let directory = repository.directory
        let referenced = Set(items.map(\.imageName) + jobs.map(\.imageName))
        try await Task.detached(priority: .utility) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
                where url.pathExtension == "image" && !referenced.contains(url.lastPathComponent) {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                try FileManager.default.removeItem(at: url)
            }
        }.value
    }

    func image(_ item: InformationItem) -> UIImage? {
        guard let repository, !item.imageName.isEmpty else { return nil }
        return UIImage(contentsOfFile: repository.directory.appendingPathComponent(item.imageName).path)
    }

    func imageURL(_ item: InformationItem) -> URL? {
        guard !item.imageName.isEmpty else { return nil }
        return repository?.directory.appendingPathComponent(item.imageName)
    }

    func thumbnail(_ item: InformationItem) -> UIImage? {
        guard let url = imageURL(item) else { return nil }
        let key = item.imageName as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 420] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        thumbnails.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }

    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        paused = scanSession?.requiresResume == true || (!foreground && !backgroundScan.isGranted)
        if paused {
            if !foreground && scanSession != nil { suspendScan(reason: "扫描已暂停，进度已保存；返回后可继续。") }
            LocalModelEngine.shared.interrupt()
            Task { await LocalModelEngine.shared.release() }
        } else if foreground && !operationRunning && scanSession?.requiresResume != true && jobs.contains(where: { $0.state != .failed }) {
            Task { await resumeJobs() }
        }
    }

    func handleMemoryWarning() {
        thumbnails.removeAllObjects()
        suspendScan(reason: "内存不足，已保存扫描进度；可以稍后继续。")
        LocalModelEngine.shared.interrupt()
        Task { await LocalModelEngine.shared.release() }
    }

    func previewScreenshots(in range: ScreenshotDateRange) async throws -> ScanPreview {
        _ = try range.interval()
        let assets = try await fetchAssets(range).filter { range.contains($0.createdAt) }
        return ScanPreview(total: assets.count, pending: assets.filter { knownOutcome(for: $0) == nil }.count, limitedAccess: limitedAccess())
    }

    func importImage(_ data: Data) async { await importImages([data]) }

    func importImages(_ dataList: [Data]) async {
        guard let repository, !operationRunning else { return }
        guard scanSession == nil else { message = "请先继续或停止上次的扫描。"; return }
        paused = !foreground
        operationRunning = true
        busy = true
        defer { finishOperation() }
        var report = ScanReport()
        var registered: [ProcessingJob] = []
        for data in dataList {
            do {
                let hash = fingerprint(data)
                if items.contains(where: { $0.fingerprint == hash }) || jobs.contains(where: { $0.fingerprint == hash }) {
                    report.include(.alreadyKnown); continue
                }
                if ignoredFingerprint(hash) { report.include(.ignored); continue }
                let imageName = UUID().uuidString + ".image"
                try data.write(to: repository.directory.appendingPathComponent(imageName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                let job = ProcessingJob(imageName: imageName, fingerprint: hash)
                try repository.save(job: job)
                jobs.append(job)
                registered.append(job)
            } catch { report.include(.failed) }
        }
        for job in registered {
            guard !paused else { break }
            report.include(await process(job))
        }
        try? repository.cleanUnreferencedImages()
        message = report.summary()
    }

    func scanScreenshotAlbum(in range: ScreenshotDateRange) async {
        guard let repository, !operationRunning else { return }
        guard scanSession == nil else { message = "请先继续或停止上次的扫描。"; return }
        do { _ = try range.interval() } catch { message = error.localizedDescription; return }
        paused = !foreground
        operationRunning = true
        scanningScreenshots = true
        busy = true
        stopRequested = false
        scanReport = ScanReport()
        scanTotal = 0
        defer { scanningScreenshots = false; finishOperation() }
        do {
            let assets = try await fetchAssets(range).filter { range.contains($0.createdAt) }
            scanTotal = assets.count
            var session = ScanSession(range: range, total: assets.count, report: ScanReport())
            var registered: [ProcessingJob] = []
            for asset in assets {
                if let outcome = knownOutcome(for: asset) {
                    session.report.include(outcome)
                } else {
                    registered.append(ProcessingJob(imageName: "", fingerprint: "asset:\(asset.id)", photoAssetIdentifier: asset.id, photoAssetCreatedAt: asset.createdAt, photoAssetModifiedAt: asset.modifiedAt, scanSessionID: session.id))
                }
            }
            // Metadata only: commit the exact selected batch before loading any image.
            try repository.transaction {
                for job in registered { try repository.save(job: job) }
                try repository.save(session: session)
            }
            jobs.append(contentsOf: registered)
            scanSession = session
            scanReport = session.report
            await runScanSession()
        } catch { message = error.localizedDescription }
    }

    func stopScanning() {
        guard scanningScreenshots || scanSession != nil else { return }
        stopRequested = true
        if !operationRunning { discardPendingScan() }
    }

    func continueScan() async {
        guard !operationRunning, var session = scanSession else { return }
        session.requiresResume = false
        do { try repository?.save(session: session) }
        catch { message = error.localizedDescription; return }
        scanSession = session
        paused = !foreground
        stopRequested = false
        await resumeJobs()
    }

    private func suspendScan(reason: String) {
        paused = true
        if var session = scanSession {
            session.requiresResume = true
            scanSession = session
            try? repository?.save(session: session)
            scanSuspended = true
        }
        message = reason
        LocalModelEngine.shared.interrupt()
    }

    private func discardPendingScan() {
        guard let repository, let session = scanSession else { return }
        let pending = jobs.filter { $0.scanSessionID == session.id && $0.state != .failed }
        do {
            try repository.transaction {
                for job in pending { try repository.delete(jobID: job.id) }
                try repository.save(session: nil)
            }
            let identifiers = Set(pending.map(\.id))
            jobs.removeAll { identifiers.contains($0.id) }
            scanSession = nil
            scanSuspended = false
            try? repository.cleanUnreferencedImages()
            message = scanReport.summary(stopped: true)
        } catch { message = error.localizedDescription }
    }

    private func runScanSession() async {
        guard let session = scanSession else { return }
        scanningScreenshots = true
        scanSuspended = false
        if stopRequested { discardPendingScan(); scanningScreenshots = false; return }
        if foreground && jobs.contains(where: { $0.scanSessionID == session.id && $0.state != .failed }) {
            backgroundScanStatus = await backgroundScan.begin(total: session.total) { [weak self] in
                guard self?.scanSession?.id == session.id else { return }
                self?.suspendScan(reason: "后台扫描已被系统暂停，进度已保存；返回 Sift 后可继续。")
            }
        }
        defer {
            backgroundScan.end(success: scanSession == nil && !stopRequested && scanReport.failed == 0)
            scanningScreenshots = false
        }
        for job in jobs where job.scanSessionID == session.id && job.state != .failed {
            guard !stopRequested, !paused else { break }
            _ = await process(job)
            backgroundScan.update(completed: scanReport.processed, total: scanTotal, subtitle: "本地识别")
            await Task.yield()
        }
        if stopRequested { discardPendingScan(); return }
        if jobs.contains(where: { $0.scanSessionID == session.id && $0.state != .failed }) {
            scanSuspended = true
            message = "扫描已暂停，已处理 \(scanReport.processed) / \(scanTotal) 张；进度已保存。"
        } else {
            do {
                try repository?.save(session: nil)
                scanSession = nil
                scanSuspended = false
                message = scanReport.summary()
            } catch { message = error.localizedDescription }
        }
    }

    private func knownOutcome(for asset: LocalPhotoAsset) -> ProcessingOutcome? {
        if jobs.contains(where: { $0.photoAssetIdentifier == asset.id }) { return .alreadyKnown }
        if let record = records["asset:\(asset.id)"] {
            // Rule upgrades revisit skipped content; unchanged historical cards retain
            // their classifications and edits. A modified photo can still be reassessed.
            if record.outcome == .accepted && record.assetModifiedAt == asset.modifiedAt { return .alreadyKnown }
            guard record.matches(asset, version: extractionVersion) else { return nil }
            return record.outcome == .ignored ? .ignored : .alreadyKnown
        }
        // Historical cards have no scan record and are kept without reclassification.
        return items.contains(where: { $0.photoAssetIdentifier == asset.id }) ? .alreadyKnown : nil
    }

    private func ignoredFingerprint(_ hash: String) -> Bool {
        records.values.contains { $0.fingerprint == hash && $0.ruleVersion == extractionVersion && $0.outcome == .ignored }
    }

    private func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func finishOperation() {
        operationRunning = false
        busy = false
        Task { await LocalModelEngine.shared.release() }
        if !paused && scanSession?.requiresResume != true && jobs.contains(where: { $0.state != .failed }) { Task { await resumeJobs() } }
    }

    private func resumeJobs() async {
        guard !operationRunning else { return }
        operationRunning = true
        busy = true
        defer { finishOperation() }
        if scanSession != nil { await runScanSession() }
        for job in jobs where job.state != .failed && job.scanSessionID == nil {
            guard !paused else { break }
            _ = await process(job)
        }
    }

    func retry(_ failedJob: ProcessingJob) async {
        guard let repository, !operationRunning else { return }
        guard scanSession == nil else { message = "请先继续或停止当前扫描，再重试失败图片。"; return }
        paused = !foreground
        operationRunning = true
        busy = true
        defer { finishOperation() }
        var job = failedJob
        job.state = .queued
        job.errorMessage = nil
        job.updatedAt = Date()
        do {
            try repository.save(job: job)
            updateJob(job)
            _ = await process(job)
        } catch { message = error.localizedDescription }
    }

    private func complete(_ job: ProcessingJob, outcome: ScanRecord.Outcome, processingOutcome: ProcessingOutcome) throws {
        guard let repository else { throw LocalError.storage("数据库不可用") }
        let record = ScanRecord(assetIdentifier: job.photoAssetIdentifier, assetModifiedAt: job.photoAssetModifiedAt, fingerprint: job.fingerprint, ruleVersion: extractionVersion, outcome: outcome)
        var updatedSession = scanSession
        if updatedSession?.id == job.scanSessionID { updatedSession?.report.include(processingOutcome) }
        try repository.finish(jobID: job.id, record: record, session: updatedSession)
        scanSession = updatedSession
        if let updatedSession { scanReport = updatedSession.report }
        records[record.key] = record
        jobs.removeAll { $0.id == job.id }
        if !job.imageName.isEmpty && !items.contains(where: { $0.imageName == job.imageName }) {
            try? FileManager.default.removeItem(at: repository.directory.appendingPathComponent(job.imageName))
        }
    }

    private func process(_ initialJob: ProcessingJob) async -> ProcessingOutcome {
        guard let repository else { return .failed }
        var job = initialJob
        do {
            guard !paused else { throw SemanticError.interrupted }
            backgroundScan.update(completed: scanReport.processed, total: scanTotal, subtitle: "读取图片")
            job.state = .loadingImage
            job.updatedAt = Date()
            try repository.save(job: job)
            updateJob(job)
            let data: Data
            if job.imageName.isEmpty {
                guard let id = job.photoAssetIdentifier, let date = job.photoAssetCreatedAt else { throw LocalError.unreadableImage }
                data = try await loadImage(LocalPhotoAsset(id: id, createdAt: date, modifiedAt: job.photoAssetModifiedAt))
                job.fingerprint = fingerprint(data)
                if items.contains(where: { $0.fingerprint == job.fingerprint && $0.photoAssetIdentifier != id }) {
                    try complete(job, outcome: .accepted, processingOutcome: .alreadyKnown)
                    return .alreadyKnown
                }
                if jobs.contains(where: { $0.id != job.id && $0.fingerprint == job.fingerprint }) {
                    // Keep the original (possibly failed) job retryable instead of replacing it.
                    var session = scanSession
                    if session?.id == job.scanSessionID { session?.report.include(.alreadyKnown) }
                    try repository.transaction {
                        try repository.delete(jobID: job.id)
                        if let session { try repository.save(session: session) }
                    }
                    scanSession = session
                    if let session { scanReport = session.report }
                    jobs.removeAll { $0.id == job.id }
                    return .alreadyKnown
                }
                if ignoredFingerprint(job.fingerprint) {
                    try complete(job, outcome: .ignored, processingOutcome: .ignored)
                    return .ignored
                }
                job.imageName = UUID().uuidString + ".image"
                try data.write(to: repository.directory.appendingPathComponent(job.imageName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try repository.save(job: job)
                updateJob(job)
            } else {
                data = try Data(contentsOf: repository.directory.appendingPathComponent(job.imageName))
            }
            guard !paused else { throw SemanticError.interrupted }
            backgroundScan.update(completed: scanReport.processed, total: scanTotal, stage: 1, subtitle: "识别文字")
            job.state = .recognizingText
            job.updatedAt = Date()
            try repository.save(job: job)
            updateJob(job)
            let document = try await recognize(data)
            guard !paused else { throw SemanticError.interrupted }
            backgroundScan.update(completed: scanReport.processed, total: scanTotal, stage: 2, subtitle: "本地理解内容")
            job.state = .extractingFields
            job.updatedAt = Date()
            try repository.save(job: job)
            updateJob(job)
            switch try await extract(document) {
            case .ignored:
                try complete(job, outcome: .ignored, processingOutcome: .ignored)
                return .ignored
            case .accepted(var item):
                let previous = items.first { ($0.photoAssetIdentifier != nil && $0.photoAssetIdentifier == job.photoAssetIdentifier) || $0.fingerprint == job.fingerprint }
                if let previous {
                    item.id = previous.id
                    item.createdAt = previous.createdAt
                    item.preserveUserEdits(from: previous)
                    item.note = previous.note
                    item.reminderAt = previous.reminderAt
                    item.intents = previous.intents
                    // A confirmation applies only to the same screenshot and OCR content.
                    if previous.displayApproval == .userConfirmed,
                       previous.fingerprint == job.fingerprint, previous.rawText == item.rawText {
                        item.confirmForDisplay()
                    } else if previous.titleWasUserEdited || previous.categoryWasUserEdited || previous.fields.contains(where: \.isUserEdited) {
                        item.displayApproval = nil
                        item.state = .needsReview
                        item.reviewReasons = Array(Set((item.reviewReasons ?? []) + ["识别结果已更新，请核对保留的修改"])).sorted()
                    }
                    if previous.state == .completed || previous.state == .archived { item.state = previous.state }
                }
                item.fingerprint = job.fingerprint
                item.imageName = job.imageName
                item.photoAssetIdentifier = job.photoAssetIdentifier
                item.requireReviewBeforeDisplay()
                try save(item)
                try complete(job, outcome: .accepted, processingOutcome: item.state == .needsReview ? .review : .added)
                if let previous, previous.imageName != job.imageName && !items.contains(where: { $0.imageName == previous.imageName }) {
                    try? FileManager.default.removeItem(at: repository.directory.appendingPathComponent(previous.imageName))
                }
                return item.state == .needsReview ? .review : .added
            }
        } catch {
            job.state = paused ? .queued : .failed
            job.errorMessage = paused ? nil : error.localizedDescription
            job.updatedAt = Date()
            var session = scanSession
            if !paused && session?.id == job.scanSessionID { session?.report.include(.failed) }
            do {
                try repository.transaction {
                    try repository.save(job: job)
                    if let session { try repository.save(session: session) }
                }
                scanSession = session
                if let session { scanReport = session.report }
            } catch { message = error.localizedDescription }
            updateJob(job)
            if !scanningScreenshots && !paused { message = error.localizedDescription }
            return paused ? .interrupted : .failed
        }
    }

    private func updateJob(_ job: ProcessingJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
    }
}

@main
struct SiftApp: App {
    @StateObject private var store = PreviewLaunchOptions.makeStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            appContent.environmentObject(store).tint(SiftStyle.ink)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background || phase == .inactive { store.setForeground(false) }
                    else if phase == .active { store.setForeground(true) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in store.handleMemoryWarning() }
        }
    }
    @ViewBuilder private var appContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-detail"), let item = store.items.first {
            NavigationStack { DetailView(item: item) }
        } else { HomeView() }
        #else
        HomeView()
        #endif
    }

}

struct HomeView: View {
    @EnvironmentObject var store: SiftStore
    @State private var selection: [PhotosPickerItem] = []
    @State private var showingScanRange = PreviewLaunchOptions.previewScan
    @State private var selectedTab = PreviewLaunchOptions.previewTab
    var body: some View {
        TabView(selection: $selectedTab) {
            collection("今天", mode: 0).tabItem { Label("今天", systemImage: "sun.max") }.tag(0)
            collection("待确认", mode: 1).tabItem { Label("待确认", systemImage: "tray") }.tag(1).badge(store.items.filter(\.requiresHumanReview).count)
            collection("信息库", mode: 2).tabItem { Label("信息库", systemImage: "square.stack") }.tag(2)
            NavigationStack {
                SettingsView()
            }.tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
        }
        .alert("Sift", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("好", role: .cancel) {} } message: { Text(store.message ?? "") }
        .sheet(isPresented: $showingScanRange) { ScreenshotScanSheet() }
        .onChange(of: selection) { _, picked in
            guard !picked.isEmpty else { return }
            store.busy = true
            Task {
                var dataList: [Data] = []
                for item in picked {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self) { dataList.append(data) }
                        else { store.message = "没有获取到图片数据。" }
                    } catch { store.message = error.localizedDescription }
                }
                await store.importImages(dataList)
                selection = []; store.busy = false
            }
        }
    }
    private func collection(_ title: String, mode: Int) -> some View {
        NavigationStack {
            CollectionView(mode: mode, selection: $selection,
                           onScanScreenshots: { showingScanRange = true })
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom) {
                    if store.busy {
                        HStack {
                            ProgressView()
                            if store.scanningScreenshots {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(store.stopRequested ? "正在结束当前截图…" : "正在扫描 \(store.scanReport.processed) / \(store.scanTotal) 张")
                                    ProgressView(value: Double(store.scanReport.processed), total: Double(max(1, store.scanTotal)))
                                    Text(store.backgroundScanStatus ?? (store.canScanInBackground ? "切到后台后可继续扫描" : "正在申请后台扫描"))
                                        .font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                                }
                                Button(store.stopRequested ? "停止中" : "停止") { store.stopScanning() }
                                    .disabled(store.stopRequested)
                                    .accessibilityIdentifier("scan.stop")
                            } else { Text("正在本地识别…") }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                    } else if store.scanSuspended {
                        HStack(spacing: 12) {
                            Image(systemName: "pause.circle").foregroundStyle(SiftStyle.ink)
                            Text("已暂停 · \(store.scanReport.processed) / \(store.scanTotal) 张").font(.subheadline)
                            Spacer(minLength: 0)
                            Button("继续") { Task { await store.continueScan() } }
                                .accessibilityIdentifier("scan.resume")
                            Button("停止") { store.stopScanning() }.accessibilityIdentifier("scan.stop")
                        }.padding(.horizontal, SiftStyle.pageInset).padding(.vertical, 12)
                            .background(SiftStyle.accent)
                    }
                }
        }
    }
}

struct CollectionView: View {
    @EnvironmentObject var store: SiftStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let mode: Int
    @Binding var selection: [PhotosPickerItem]
    var onScanScreenshots: () -> Void
    @State private var query = ""
    @State private var category: CategoryGroup? = PreviewLaunchOptions.previewCategory
    @State private var selectedIntents: Set<IntentTag> = []
    @State private var showingFilters = false
    @State private var expandedGroups: Set<CategoryGroup> = []

    private var baseItems: [InformationItem] {
        store.items.filter { mode == 2 ? !$0.requiresHumanReview : (mode == 1 ? $0.requiresHumanReview : $0.state == .pending && !$0.requiresHumanReview) }
    }
    private var filtering: Bool { !query.isEmpty || category != nil || !selectedIntents.isEmpty }
    var visible: [InformationItem] {
        baseItems.filter { item in
            let categoryMatches = category == nil || category == item.category.group
            let intentMatches = selectedIntents.isEmpty || selectedIntents.allSatisfy { item.intents.contains($0) }
            let searchable = [item.title, item.rawText, item.code, item.amount, item.note, item.category.displayName, item.intents.map(\.displayName).joined(separator: " "), item.fields.map(\.value).joined(separator: " ")].joined(separator: " ")
            return categoryMatches && intentMatches && (query.isEmpty || searchable.localizedStandardContains(query))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                masthead
                searchBar
                if mode == 1 {
                    Text("核对原图，修改分类或字段，再确认加入首页。")
                        .font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                }
                if !store.jobs.isEmpty {
                    ProcessingQueueCard(jobs: store.jobs) { job in Task { await store.retry(job) } }
                }
                if filtering {
                    HStack {
                        Text("筛选结果 · \(visible.count) 条").font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                        Spacer()
                        Button("重置") { clearFilters() }.font(.subheadline).frame(minWidth: 44, minHeight: 44)
                    }
                }
                if visible.isEmpty { emptyState }
                VStack(spacing: 24) {
                        ForEach(CategoryGroup.allCases.filter { category == nil || category == $0 }) { group in
                            let cards = visible.filter { $0.category.group == group }.sorted { $0.createdAt > $1.createdAt }
                            CardStackSection(group: group, items: cards, expanded: expandedGroups.contains(group) || filtering) {
                                if expandedGroups.contains(group) { expandedGroups.remove(group) }
                                else { expandedGroups.insert(group) }
                            }
                        }
                    }
            }.padding(.horizontal, SiftStyle.pageInset).padding(.top, 8).padding(.bottom, 30)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(SiftStyle.background).scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showingFilters) { FilterSheet(category: $category, selectedIntents: $selectedIntents) }
    }

    private var headline: some View {
        Text(mode == 0 ? "今天" : mode == 1 ? "待确认" : "信息库")
            .font(.title.weight(.bold)).foregroundStyle(SiftStyle.ink)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("home.tagline")
    }

    private var masthead: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    headline
                    HStack(spacing: 10) { mastheadActions; Spacer(minLength: 0) }
                }
            } else {
                HStack(spacing: 10) { headline; Spacer(minLength: 10); mastheadActions }
            }
        }
    }

    @ViewBuilder private var mastheadActions: some View {
            Button(action: onScanScreenshots) {
                Label("扫描", systemImage: "viewfinder")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(SiftStyle.accentInk)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(SiftStyle.accent, in: Capsule())
            }.buttonStyle(SiftPressStyle()).disabled(store.scanningScreenshots)
                .accessibilityLabel("扫描截图相册").accessibilityIdentifier("home.scan")
            PhotosPicker(selection: $selection, maxSelectionCount: 50, matching: .images) {
                Image(systemName: "plus").font(.system(size: 19, weight: .medium)).foregroundStyle(SiftStyle.ink)
                    .frame(width: 44, height: 44).background(SiftStyle.surface, in: Circle())
                    .overlay(Circle().stroke(SiftStyle.border, lineWidth: 0.5))
            }.buttonStyle(SiftPressStyle()).accessibilityLabel("导入截图").disabled(store.busy)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(SiftStyle.ink)
                .accessibilityHidden(true)
            TextField(text: $query, prompt: Text("搜索截图中的信息").foregroundStyle(SiftStyle.secondaryInk)) { Text("搜索截图") }
                .font(.subheadline).accessibilityLabel("搜索截图").submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(SiftStyle.secondaryInk).frame(width: 44, height: 44)
                }.accessibilityLabel("清除搜索")
            }
            Rectangle().fill(SiftStyle.border).frame(width: 1, height: 22).accessibilityHidden(true)
            Button { showingFilters = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(category == nil && selectedIntents.isEmpty ? SiftStyle.ink : SiftStyle.accentInk)
                    .frame(width: 44, height: 44)
                    .background(category == nil && selectedIntents.isEmpty ? Color.clear : SiftStyle.accent, in: Circle())
            }.buttonStyle(SiftPressStyle()).accessibilityLabel("筛选分类")
                .accessibilityValue("\(category?.displayName ?? "全部分类")，\(selectedIntents.count) 个使用目的已选择")
        }.padding(.leading, 18).padding(.trailing, 4).frame(minHeight: 54)
            .siftPaper(radius: 28)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ScreenshotIllustration()
            Text(filtering ? "暂时没有找到。" : mode == 1 ? "都确认好了。" : "从一张截图开始。")
                .font(.title2.weight(.medium)).foregroundStyle(SiftStyle.ink)
            Text(filtering ? "换个关键词，或试试其他筛选条件。" : mode == 1 ? "需要确认的信息，会出现在这里。" : "选一段时间，让有用的信息各归其位。")
                .font(.subheadline).foregroundStyle(SiftStyle.secondaryInk).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if filtering {
                Button("清除筛选") { clearFilters() }.frame(minHeight: 44)
            } else if mode != 1 {
                VStack(spacing: 6) {
                    Button(action: onScanScreenshots) { Label("扫描截图相册", systemImage: "viewfinder") }
                        .buttonStyle(SiftPrimaryButton()).disabled(store.scanningScreenshots)
                    PhotosPicker(selection: $selection, maxSelectionCount: 50, matching: .images) {
                        Text("手动选择截图").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(SiftPressStyle()).disabled(store.busy).accessibilityLabel("导入截图")
                }.padding(.top, 6)
            }
        }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 32)
    }

    private func clearFilters() { query = ""; category = nil; selectedIntents = [] }
}

struct ProcessingQueueCard: View {
    let jobs: [ProcessingJob]
    let retry: (ProcessingJob) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(jobs.contains { $0.state == .failed } ? "有截图需要重新处理" : "正在整理截图", systemImage: "square.stack")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(jobs.count) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(jobs.prefix(3))) { job in
                HStack(spacing: 8) {
                    Circle()
                        .fill(job.state == .failed ? Color.red : SiftStyle.accent)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.state == .failed ? (job.errorMessage ?? "处理失败") : job.state.displayName)
                            .font(.caption.weight(.medium))
                        Text("可继续处理这张截图")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if job.state == .failed {
                        Button("重试") { retry(job) }
                            .font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .padding(16)
        .background(SiftStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(SiftStyle.border, lineWidth: 0.5))
    }
}

struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var category: CategoryGroup?
    @Binding var selectedIntents: Set<IntentTag>

    var body: some View {
        NavigationStack {
            List {
                Section("内容大类") {
                    filterRow("全部内容", symbol: "square.grid.2x2", group: nil, selected: category == nil) {
                        category = nil
                    }
                    ForEach(CategoryGroup.allCases) { value in
                        filterRow(value.displayName, symbol: value.symbol, group: value, selected: category == value) {
                            category = value
                        }
                    }
                }
                Section("使用目的") {
                    ForEach(IntentTag.allCases, id: \.self) { value in
                        Button {
                            if selectedIntents.contains(value) { selectedIntents.remove(value) }
                            else { selectedIntents.insert(value) }
                        } label: {
                            HStack {
                                Label(value.displayName, systemImage: value.symbol)
                                Spacer()
                                Image(systemName: selectedIntents.contains(value) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIntents.contains(value) ? SiftStyle.ink : SiftStyle.secondaryInk)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(SiftStyle.background)
            .navigationTitle("筛选信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清除") { category = nil; selectedIntents = [] }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func filterRow(_ title: String, symbol: String, group: CategoryGroup?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(group.map(SiftStyle.categoryTint) ?? .primary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? (group.map(SiftStyle.categoryTint) ?? SiftStyle.ink) : .secondary)
            }
        }
        .foregroundStyle(.primary)
    }
}

struct DetailView: View {
    @EnvironmentObject var store: SiftStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State var item: InformationItem
    @State private var reminderDate = Date().addingTimeInterval(3600)
    @State private var calendarDate = Date().addingTimeInterval(3600)
    @State private var scheduling = false
    @State private var addingToCalendar = false
    @State private var showingScreenshot = false
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            detailHero
            DetailSection("关键信息") {
                ForEach(item.category.cardFields) { slot in
                    editField(slot.label, value: cardFieldBinding(slot))
                }
            }
            if item.requiresHumanReview {
                let primaryKinds = Set(item.category.cardFields.compactMap(\.editableKind))
                let extraFields = item.fields.filter { !primaryKinds.contains($0.kind) && ![FieldKind.note, .code, .amount].contains($0.kind) }
                if !extraFields.isEmpty {
                    SiftDisclosureSection("其他识别字段 · 可修改") {
                        ForEach(extraFields) { field in
                            editField(field.kind.displayName, value: fieldBinding(field.id))
                        }
                    }
                }
            }
            SiftDisclosureSection("信息设置") {
                if !item.category.cardFields.contains(where: { if case .title = $0.source { return true }; return false }) {
                    editField("标题", value: titleBinding)
                }
                Picker("类型", selection: Binding(get: { item.category }, set: { item.category = $0; item.categoryWasUserEdited = true })) { ForEach(Category.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                if !item.code.isEmpty && !item.category.cardFields.contains(where: { $0.editableKind == .code }) {
                    editField("取件码 / 取餐号", value: legacyBinding(kind: .code))
                }
                if !item.amount.isEmpty && !item.category.cardFields.contains(where: { $0.editableKind == .amount }) {
                    editField("实付金额", value: legacyBinding(kind: .amount))
                }
                editField("备注", value: Binding(get: { item.note }, set: { item.note = $0; item.setUserEditedValue($0, for: .note) }))
                Picker("状态", selection: Binding(get: { item.displayState }, set: {
                    item.state = $0
                    if $0 == .needsReview { item.displayApproval = nil }
                })) {
                    ForEach(ItemState.allCases.filter { !item.requiresHumanReview || $0 != .pending }, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            SiftDisclosureSection("使用目的") {
                ForEach(IntentTag.allCases, id: \.self) { tag in
                    Button {
                        if item.intents.contains(tag) { item.intents.removeAll { $0 == tag } }
                        else { item.intents.append(tag) }
                    } label: {
                        HStack {
                            Label(tag.displayName, systemImage: tag.symbol)
                            Spacer()
                            Image(systemName: item.intents.contains(tag) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.intents.contains(tag) ? SiftStyle.ink : SiftStyle.secondaryInk)
                        }
                        .frame(minHeight: 44)
                    }
                    .foregroundStyle(.primary)
                }
            }
            if item.classificationConfidence > 0 {
                SiftDisclosureSection("识别依据") {
                    HStack {
                        Text("分类置信度")
                        Spacer()
                        Text("\(Int(item.classificationConfidence * 100))%")
                    }
                    .font(.subheadline)
                    if !item.matchedKeywords.isEmpty {
                        Text("匹配关键词：" + item.matchedKeywords.joined(separator: "、"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.classificationConfidence < 0.8 ? "建议确认分类后再继续处理。" : "分类来自旧版本地规则，未上传截图或文字。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let reasons = item.reviewReasons, !reasons.isEmpty {
                DetailSection(item.requiresHumanReview ? "需要确认" : "已核对的问题") {
                    ForEach(reasons, id: \.self) { Text($0).font(.subheadline) }
                }
            }
            if !item.fields.isEmpty {
                SiftDisclosureSection("识别详情") {
                    if item.classificationVersion.hasPrefix("qwen3-") || item.classificationVersion.hasPrefix("lfm2.5-") {
                        Text("字段来源见下方原文。文字识别分数只表示清晰度，不代表信息一定正确。")
                            .font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                    }
                    ForEach(item.fields) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(field.kind.displayName).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(field.isUserEdited ? "用户修改" : "截图原文")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(field.displayValue).font(.body.monospacedDigit())
                            if field.isUserEdited {
                                Text("来源：用户修改").font(.caption).foregroundStyle(.secondary)
                            } else if !field.sourceBlockIDs.isEmpty, let document = item.ocrDocument {
                                let source = field.sourceBlockIDs.compactMap { id in document.blocks.first(where: { $0.id == id })?.text }.joined(separator: "\n")
                                Label("来源：\(source)", systemImage: "scope")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(field.isUserEdited ? "来源：用户修改" : "来源：截图文字")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        if field.id != item.fields.last?.id { Divider() }
                    }
                }
            }
            if let scenes = item.recognizedScenes, scenes.count > 1 {
                SiftDisclosureSection("同图其他事项") {
                    ForEach(Array(scenes.dropFirst())) { scene in
                        VStack(alignment: .leading, spacing: 8) {
                            if item.requiresHumanReview {
                                editField("事项标题", value: sceneTitleBinding(scene.id))
                                Picker("类型", selection: sceneCategoryBinding(scene.id)) {
                                    ForEach(Category.allCases, id: \.self) { Text($0.displayName).tag($0) }
                                }
                            } else { Text(scene.title).font(.headline) }
                            ForEach(scene.reviewReasons, id: \.self) { reason in Text(reason).font(.caption).foregroundStyle(SiftStyle.secondaryInk) }
                            ForEach(scene.fields) { field in
                                if item.requiresHumanReview {
                                    editField(field.kind.displayName, value: sceneFieldBinding(sceneID: scene.id, fieldID: field.id))
                                } else {
                                    Text("\(field.kind.displayName)：\(field.displayValue)").font(.subheadline)
                                }
                                if let document = item.ocrDocument {
                                    Text(field.sourceBlockIDs.compactMap { id in document.blocks.first { $0.id == id }?.text }.joined(separator: "\n"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
            if !item.code.isEmpty {
                DetailSection("随时可用") {
                    Button { UIPasteboard.general.string = item.code; store.message = "已复制" } label: {
                        Label("复制 \(item.code)", systemImage: "doc.on.doc").frame(minHeight: 44)
                    }
                }
            } else if !item.amount.isEmpty {
                DetailSection("随时可用") {
                    Button { UIPasteboard.general.string = item.fields.first { $0.kind == .amount }?.displayValue ?? item.amount; store.message = "已复制" } label: {
                        Label("复制金额 \(item.fields.first { $0.kind == .amount }?.displayValue ?? item.amount)", systemImage: "doc.on.doc").frame(minHeight: 44)
                    }
                }
            }
            if let place = item.fields.first(where: { $0.kind == .location || $0.kind == .address })?.value {
                DetailSection("本地动作") {
                    Button { LocalActions.openMap(for: place) } label: {
                        Label("在地图中打开", systemImage: "map").frame(minHeight: 44)
                    }
                }
            }
            SiftDisclosureSection("给未来的自己提个醒") {
                DatePicker("提醒时间", selection: $reminderDate, in: Date().addingTimeInterval(60)...)
                Button("保存并设置提醒") {
                    scheduling = true
                    Task {
                        defer { scheduling = false }
                        do {
                            guard reminderDate > Date() else { store.message = "请选择未来时间。"; return }
                            item.state = .pending
                            try store.save(item)
                            try await LocalReminders.schedule(item, at: reminderDate)
                            item.reminderAt = reminderDate
                            do { try store.save(item) }
                            catch { LocalReminders.cancel(item.id); item.reminderAt = nil; throw error }
                        } catch { store.message = error.localizedDescription }
                    }
                }.disabled(scheduling || item.requiresHumanReview).frame(minHeight: 44)
                if scheduling { ProgressView("正在设置提醒…") }
                if item.reminderAt != nil {
                    Button("取消提醒", role: .destructive) { LocalReminders.cancel(item.id); item.reminderAt = nil; persist() }
                }
            }
            if item.category == .event || item.fields.contains(where: { $0.kind == .date || $0.kind == .time }) {
                SiftDisclosureSection("添加到日历") {
                    DatePicker("开始时间", selection: $calendarDate, in: Date()...)
                    Button {
                        addingToCalendar = true
                        Task {
                            defer { addingToCalendar = false }
                            do {
                                try await LocalActions.addToCalendar(item, at: calendarDate)
                                store.message = "已添加到日历"
                            } catch { store.message = error.localizedDescription }
                        }
                    } label: {
                        Label("添加到系统日历", systemImage: "calendar.badge.plus").frame(minHeight: 44)
                    }
                    .disabled(addingToCalendar)
                    if addingToCalendar { ProgressView("正在添加…") }
                }
            }
            SiftDisclosureSection("截图原文") { Text(item.rawText.isEmpty ? "未识别到文字，可手动填写信息。" : item.rawText).font(.body).textSelection(.enabled) }
          }.padding(SiftStyle.pageInset).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(SiftStyle.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if item.requiresHumanReview {
                    Button {
                        let previous = item
                        item.confirmForDisplay()
                        if persist() { store.message = "已确认，信息已加入首页" }
                        else { item = previous }
                    } label: { Label("确认并加入首页", systemImage: "checkmark") }
                        .buttonStyle(SiftPrimaryButton()).disabled(!canConfirm)
                        .accessibilityIdentifier("detail.confirm")
                    Button("保存修改，稍后确认") {
                        if persist() { store.message = "修改已保存，仍在待确认中" }
                    }.frame(minHeight: 44).accessibilityIdentifier("detail.saveDraft")
                } else {
                    Button { if persist() { store.message = "修改已保存" } } label: {
                        Label("保存修改", systemImage: "checkmark")
                    }.buttonStyle(SiftPrimaryButton())
                }
            }.padding(.horizontal, SiftStyle.pageInset).padding(.vertical, 12).background(SiftStyle.background)
        }
        .fullScreenCover(isPresented: $showingScreenshot) { ScreenshotViewer(url: store.imageURL(item), title: item.title) }
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(SiftStyle.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle("信息详情")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var featuredSlot: CategoryCardField? {
        let slots = item.category.cardFields
        switch item.category.group {
        case .collectionCodes: return slots.first { $0.editableKind == .code }
        case .schedules: return slots.first { $0.source == .eventDateTime || $0.editableKind == .date }
        case .purchases:
            if !item.amount.isEmpty || item.fields.contains(where: { $0.kind == .amount && !$0.value.isEmpty }) {
                return CategoryCardField(label: "实付金额", source: .fields(primary: .amount, fallbacks: []))
            }
            return slots.first { $0.editableKind == .price }
        case .collections: return slots.last { $0.source != .title }
        }
    }

    private var detailHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(item.category.group.shortTitle, systemImage: item.category.group.symbol)
                    .font(.subheadline.weight(.medium)).foregroundStyle(SiftStyle.categoryTint(item.category.group))
                Spacer()
                if item.displayState != .pending { SiftStateBadge(state: item.displayState) }
            }
            Text(item.title).font(.title2.weight(.semibold))
                .foregroundStyle(SiftStyle.ink).fixedSize(horizontal: false, vertical: true)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 20) { featuredInformation; detailImageButton }
            } else {
                HStack(alignment: .top, spacing: 20) { featuredInformation; detailImageButton }
            }
        }.padding(20).siftPaper()
    }

    private var featuredInformation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let slot = featuredSlot, let value = item.cardValue(for: slot) {
                Text(slot.label).font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                Text(value).font(slot.editableKind == .code || slot.editableKind == .amount ? .system(.largeTitle, design: .rounded).weight(.semibold) : .title3.weight(.medium))
                    .monospacedDigit().foregroundStyle(SiftStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.createdAt.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))))
                .font(.caption).foregroundStyle(SiftStyle.secondaryInk)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailImageButton: some View {
        Button { showingScreenshot = true } label: {
            VStack(spacing: 6) {
                ZStack {
                    SiftStyle.surface
                    if let image = store.thumbnail(item) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else { Image(systemName: "photo").foregroundStyle(SiftStyle.secondaryInk) }
                }.frame(width: typeSize.isAccessibilitySize ? 140 : 76, height: typeSize.isAccessibilitySize ? 180 : 98)
                    .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                Label("原图", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(width: typeSize.isAccessibilitySize ? 140 : 76).contentShape(Rectangle())
        }.buttonStyle(SiftPressStyle()).accessibilityLabel("打开原始截图").accessibilityIdentifier("detail.image")
    }

    private func editField(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: value, axis: .vertical).accessibilityLabel(title).padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(SiftStyle.background.shadow(.inner(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SiftStyle.border, lineWidth: 0.5))
                }
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { item.title },
            set: { item.title = $0; item.titleWasUserEdited = true }
        )
    }

    private func cardFieldBinding(_ slot: CategoryCardField) -> Binding<String> {
        Binding(
            get: { item.cardValue(for: slot) ?? "" },
            set: { item.setCardValue($0, for: slot) }
        )
    }

    private func legacyBinding(kind: FieldKind) -> Binding<String> {
        Binding(
            get: {
                switch kind {
                case .code: return item.code
                case .amount: return item.amount
                default: return ""
                }
            },
            set: { value in
                switch kind {
                case .code: item.code = value
                case .amount: item.amount = value
                default: break
                }
                item.setUserEditedValue(value, for: kind)
            }
        )
    }

    private var canConfirm: Bool {
        !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        item.fields.contains { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
        (item.recognizedScenes ?? []).dropFirst().allSatisfy { scene in
            !scene.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            scene.fields.contains { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private func fieldBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { item.fields.first { $0.id == id }?.displayValue ?? "" }, set: { value in
            guard let index = item.fields.firstIndex(where: { $0.id == id }) else { return }
            item.fields[index].value = value
            item.fields[index].isUserEdited = true
        })
    }

    private func sceneFieldBinding(sceneID: UUID, fieldID: UUID) -> Binding<String> {
        Binding(get: {
            item.recognizedScenes?.first { $0.id == sceneID }?.fields.first { $0.id == fieldID }?.displayValue ?? ""
        }, set: { value in
            guard let index = item.recognizedScenes?.firstIndex(where: { $0.id == sceneID }),
                  let field = item.recognizedScenes?[index].fields.firstIndex(where: { $0.id == fieldID }) else { return }
            item.recognizedScenes?[index].fields[field].value = value
            item.recognizedScenes?[index].fields[field].isUserEdited = true
        })
    }

    private func sceneTitleBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { item.recognizedScenes?.first { $0.id == id }?.title ?? "" }, set: { value in
            guard let index = item.recognizedScenes?.firstIndex(where: { $0.id == id }) else { return }
            item.recognizedScenes?[index].title = value
        })
    }

    private func sceneCategoryBinding(_ id: UUID) -> Binding<Category> {
        Binding(get: { item.recognizedScenes?.first { $0.id == id }?.category ?? .other }, set: { value in
            guard let index = item.recognizedScenes?.firstIndex(where: { $0.id == id }) else { return }
            item.recognizedScenes?[index].category = value
        })
    }

    @discardableResult private func persist() -> Bool {
        do {
            if item.state == .completed || item.state == .archived { item.reminderAt = nil }
            item.requireReviewBeforeDisplay()
            if item.recognizedScenes?.isEmpty == false {
                item.recognizedScenes?[0].category = item.category
                item.recognizedScenes?[0].title = item.title
                item.recognizedScenes?[0].fields = item.fields
            }
            try store.save(item)
            if item.reminderAt == nil { LocalReminders.cancel(item.id) }
            return true
        } catch { store.message = error.localizedDescription; return false }
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(SiftStyle.accentInk).frame(width: 64, height: 64)
                            .background(SiftStyle.blush, in: RoundedRectangle(cornerRadius: 20))
                        Text("你的截图，只留在你的设备上")
                            .font(.system(.title, design: .serif).weight(.medium))
                        Text("Sift 不需要账号，也不把截图交给云端模型处理。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    DetailSection("本地处理") {
                        privacyRow("截图和 OCR 原文", "仅收录的信息保存在 Sift 本地；无关截图的临时副本会清理")
                        privacyRow("文字识别和分类", "使用 Apple Vision 与内置中文模型完成，识别无需联网")
                        privacyRow("搜索、字段和提醒", "在设备上执行，不上传搜索内容")
                        privacyRow("截图相册扫描", "先选择日期并点击开始，只处理所选时段；支持有限照片访问")
                    }
                    DetailSection("你需要知道") {
                        privacyRow("照片选择器", "只有你主动选择的照片会被读取；iCloud 图片遵循系统设置")
                        privacyRow("通知", "通知只显示有信息需要处理，不包含截图原文、金额、地址或验证码")
                        privacyRow("地图和日历", "只有你主动点击对应按钮时，系统应用才会接收你选择的内容")
                    }
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(SiftStyle.background)
            .navigationTitle("隐私说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    private func privacyRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(SiftStyle.categoryTint(.purchases))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
