import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject private var store: SiftStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AutomaticRecognitionSettings.enabledKey) private var automaticRecognitionEnabled = false
    @AppStorage(AutomaticRecognitionSettings.retentionDaysKey) private var automaticRetentionDays = AutomaticRecognitionSettings.defaultRetentionDays
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var usage: SettingsUsage?
    @State private var showingPrivacy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置").font(.title.weight(.bold)).foregroundStyle(SiftStyle.ink)
                    .frame(minHeight: 44).accessibilityAddTraits(.isHeader)
                automaticRecognitionCard
                VStack(spacing: 0) {
                    NavigationLink { PhotoAccessView() } label: {
                        SettingsRow(title: "照片权限", detail: photoStatus.siftDescription, symbol: "photo")
                    }.accessibilityIdentifier("settings.photos")
                    Divider()
                    NavigationLink { LocalModelSettingsView() } label: {
                        SettingsRow(title: "本地识别", detail: "\(LocalModelIdentity.bundled.displayName) · 离线运行", symbol: "cpu")
                    }.accessibilityIdentifier("settings.model")
                    Divider()
                    NavigationLink { StorageSettingsView() } label: {
                        SettingsRow(title: "存储空间", detail: usage?.dataBytes.map(SettingsUsage.format) ?? "查看本地数据与缓存", symbol: "internaldrive")
                    }.accessibilityIdentifier("settings.storage")
                    Divider()
                    Button { showingPrivacy = true } label: {
                        SettingsRow(title: "隐私说明", detail: "截图在设备上处理与保存", symbol: "lock.shield")
                    }.accessibilityIdentifier("settings.privacy")
                }.padding(.horizontal, 18).siftPaper().buttonStyle(SiftPressStyle())
                Text(version).font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }.padding(.horizontal, SiftStyle.pageInset).padding(.top, 8).padding(.bottom, 32)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(SiftStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingPrivacy) { PrivacyView() }
            .task { await refresh() }
            .onAppear {
                if !AutomaticRecognitionSettings.availableRetentionDays.contains(automaticRetentionDays) {
                    automaticRetentionDays = AutomaticRecognitionSettings.defaultRetentionDays
                }
            }
            .onChange(of: automaticRecognitionEnabled) { _, enabled in
                Task { await store.updateAutomaticRecognition(enabled: enabled, retentionDays: automaticRetentionDays) }
            }
            .onChange(of: automaticRetentionDays) { _, days in
                guard automaticRecognitionEnabled else { return }
                Task { await store.updateAutomaticRecognition(enabled: true, retentionDays: days) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
    }

    private var automaticRecognitionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Label("自动识别", systemImage: "sparkles.rectangle.stack")
                    .font(.headline).foregroundStyle(SiftStyle.ink)
                Spacer(minLength: 12)
                Toggle("自动识别", isOn: $automaticRecognitionEnabled)
                    .labelsHidden().tint(SiftStyle.accent)
                    .accessibilityIdentifier("settings.autoRecognition.toggle")
            }
            Picker("识别并保留最近", selection: $automaticRetentionDays) {
                ForEach(AutomaticRecognitionSettings.availableRetentionDays, id: \.self) { days in
                    Text("\(days) 天").tag(days)
                }
            }.pickerStyle(.segmented).accessibilityIdentifier("settings.autoRecognition.retention")
            Text(automaticRecognitionEnabled
                 ? "打开 Sift 或应用在前台检测到新截图时，自动处理最近所选天数内尚未识别的截图。已开始的扫描可在 iOS 授权时切到后台继续；应用挂起或退出时，新截图会在下次打开 Sift 后检查。超期卡片和本地副本从 Sift 移除，照片原图保留。"
                 : "开启后会在打开 Sift 或应用前台发现新截图时，自动处理最近所选天数内尚未识别的图片，并按此期限清理 Sift 中的旧截图。")
                .font(.footnote).foregroundStyle(SiftStyle.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if let status = store.automaticRecognitionStatus {
                Text(status).font(.footnote.weight(.medium)).foregroundStyle(SiftStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.autoRecognition.status")
            }
        }
        .padding(18).siftPaper(radius: 18)
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Sift · \(version)"
    }

    private func refresh() async {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        usage = try? await SettingsUsage.read(dataDirectory: store.dataDirectory)
    }
}

private struct SettingsRow: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(SiftStyle.accentInk)
                .frame(width: 40, height: 40)
                .background(SiftStyle.accent, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(SiftStyle.ink)
                Text(detail).font(.footnote).foregroundStyle(SiftStyle.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SiftStyle.secondaryInk).accessibilityHidden(true)
        }.foregroundStyle(SiftStyle.ink).padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
    }
}

private extension PHAuthorizationStatus {
    var siftDescription: String {
        switch self {
        case .authorized: return "允许访问全部照片"
        case .limited: return "仅允许访问所选照片"
        case .notDetermined: return "尚未授权"
        case .denied: return "已关闭照片访问"
        case .restricted: return "照片访问受到系统限制"
        @unknown default: return "请检查系统照片设置"
        }
    }
}

private struct PhotoAccessView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var requesting = false

    var body: some View {
        SettingsPage(title: "照片权限") {
            DetailSection("当前权限") {
                Text(status.siftDescription).font(.headline).foregroundStyle(SiftStyle.ink)
                    .accessibilityIdentifier("settings.photos.status")
                Text("授权后，扫描仍需先选择日期，再点击开始。")
                    .font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                if status == .limited {
                    Text("数量与扫描范围只包含你已授权的截图。")
                        .font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                    Button("调整可访问照片") { presentLimitedPicker() }
                        .frame(minHeight: 44).accessibilityIdentifier("settings.photos.limited")
                }
            }
            if status == .notDetermined {
                Button {
                    requesting = true
                    Task {
                        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        requesting = false
                    }
                } label: {
                    if requesting { ProgressView() } else { Text("授权照片访问") }
                }.buttonStyle(SiftPrimaryButton()).disabled(requesting)
                    .accessibilityIdentifier("settings.photos.request")
            } else {
                Button("打开系统设置") { openSettings() }.buttonStyle(SiftPrimaryButton())
                    .accessibilityIdentifier("settings.photos.system")
            }
            Text("手动导入可通过系统照片选择器选择图片。")
                .font(.footnote).foregroundStyle(SiftStyle.secondaryInk)
        }.onChange(of: scenePhase) { _, phase in
            if phase == .active { status = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        }.onAppear { status = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { openSettings(); return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in
            Task { @MainActor in status = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        }
    }
}

private struct LocalModelSettingsView: View {
    @State private var usage: SettingsUsage?
    @State private var errorMessage: String?
    var body: some View {
        SettingsPage(title: "本地识别") {
            DetailSection(LocalModelIdentity.bundled.displayName) {
                Text("4bit · 场景与状态判断").font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                Text("明确场景直接提取；复杂内容由内置模型判断用途与安排性质，号码、金额和时间由原文校验提取。识别在 iPhone 本机完成。")
                    .font(.body).foregroundStyle(SiftStyle.ink)
                if let usage {
                    infoRow("模型资源", usage.modelPresent ? "已内置" : "资源缺失或异常")
                    infoRow("占用空间", SettingsUsage.format(usage.modelBytes))
                    if !usage.modelPresent {
                        Text("请安装包含完整模型资源的 Sift 版本。")
                            .font(.footnote).foregroundStyle(SiftStyle.warning)
                    }
                } else if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(SiftStyle.warning)
                } else { ProgressView("正在读取模型信息…") }
            }
            Text("模型随安装包内置，使用时无需联网下载。")
                .font(.footnote).foregroundStyle(SiftStyle.secondaryInk)
            SiftDisclosureSection("模型信息") {
                Text(SemanticPolicy.modelID).font(.footnote).textSelection(.enabled)
                Text("版本 \(SemanticPolicy.modelRevision.prefix(8)) · \(LocalModelIdentity.bundled.license)")
                    .font(.footnote).foregroundStyle(SiftStyle.secondaryInk)
            }
        }.task {
            do { usage = try await SettingsUsage.read(dataDirectory: nil) }
            catch { errorMessage = "无法读取本地模型信息。" }
        }
    }
}

private struct StorageSettingsView: View {
    @EnvironmentObject private var store: SiftStore
    @State private var usage: SettingsUsage?
    @State private var errorMessage: String?
    @State private var cleaning = false
    @State private var feedback: String?
    var body: some View {
        SettingsPage(title: "存储空间") {
            DetailSection("设备上的数据") {
                infoRow("信息卡", "\(store.items.count) 张")
                infoRow("未完成任务", "\(store.jobs.count) 个")
                if let usage {
                    infoRow("本地数据与截图", usage.dataBytes.map(SettingsUsage.format) ?? "暂不可用")
                    infoRow("内置模型", SettingsUsage.format(usage.modelBytes))
                } else if errorMessage == nil { ProgressView("正在统计空间…") }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(SiftStyle.warning) }
            }
            Text("清理未使用的临时图片和缩略图缓存，保留信息卡、原图和可重试任务。")
                .font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
            Button {
                cleaning = true
                errorMessage = nil
                feedback = nil
                Task {
                    defer { cleaning = false }
                    do {
                        try await store.clearUnusedFiles()
                        await refresh()
                        if errorMessage == nil { feedback = "缓存已清理" }
                    } catch { errorMessage = error.localizedDescription }
                }
            } label: {
                if cleaning { ProgressView() } else { Text("清理缓存") }
            }.buttonStyle(SiftPrimaryButton()).disabled(cleaning || store.busy)
                .accessibilityIdentifier("settings.storage.clean")
            if store.busy && !cleaning {
                Text("当前正在整理截图，结束后可以清理。")
                    .font(.footnote).foregroundStyle(SiftStyle.secondaryInk)
            }
            if let feedback {
                Label(feedback, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(SiftStyle.ink)
            }
        }.task { await refresh() }
    }
    private func refresh() async {
        do { usage = try await SettingsUsage.read(dataDirectory: store.dataDirectory) }
        catch { errorMessage = "无法统计本地空间，请稍后再试。" }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(SiftStyle.pageInset).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(SiftStyle.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(SiftStyle.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
    }
}

private func infoRow(_ title: String, _ value: String) -> some View {
    ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(SiftStyle.secondaryInk)
            Spacer(minLength: 16)
            Text(value).foregroundStyle(SiftStyle.ink)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(SiftStyle.secondaryInk)
            Text(value).foregroundStyle(SiftStyle.ink)
        }
    }.font(.subheadline).accessibilityElement(children: .combine)
}

/// Inspect metadata only: opening Settings never loads screenshots or starts inference.
private struct SettingsUsage: Sendable {
    let dataBytes: Int64?
    let modelBytes: Int64
    let modelPresent: Bool

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func read(dataDirectory: URL?) async throws -> SettingsUsage {
        let modelDirectory = Bundle.main.url(forResource: "LocalModel", withExtension: nil)
        return try await Task.detached(priority: .utility) {
            let dataBytes = try dataDirectory.map { try size(of: $0) }
            let modelBytes = try modelDirectory.map { try size(of: $0) } ?? 0
            return SettingsUsage(dataBytes: dataBytes, modelBytes: modelBytes, modelPresent: hasModel(at: modelDirectory))
        }.value
    }

    private static func size(of directory: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var bytes: Int64 = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { bytes += try size(of: url) }
            else if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }

    private struct Manifest: Decodable {
        struct File: Decodable { let name: String; let bytes: Int64 }
        let model: String
        let revision: String
        let files: [File]
    }
    private static func hasModel(at directory: URL?) -> Bool {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.model == SemanticPolicy.modelID, manifest.revision == SemanticPolicy.modelRevision,
              Set(manifest.files.map(\.name)).isSuperset(of: ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]) else { return false }
        return manifest.files.allSatisfy { file in
            guard !file.name.contains("/"), !file.name.contains(".."),
                  let values = try? directory.appendingPathComponent(file.name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && Int64(values.fileSize ?? 0) == file.bytes
        }
    }
}
