import SwiftUI

struct ScreenshotScanSheet: View {
    @EnvironmentObject private var store: SiftStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var range = ScreenshotDateRange.recent(days: 7)
    @State private var preview: ScanPreview?
    @State private var previewRange: ScreenshotDateRange?
    @State private var loading = false
    @State private var error: String?

    private var canBegin: Bool {
        !loading && error == nil && previewRange == range && (preview?.pending ?? 0) > 0 && !store.busy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("选择截图日期，准备好后再开始。")
                        .font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 16) {
                        SiftEyebrow(title: "截图日期")
                        HStack(spacing: 10) {
                            preset(days: 7, identifier: "scan.range.last7")
                            preset(days: 30, identifier: "scan.range.last30")
                        }
                        VStack(spacing: 14) {
                            DatePicker("开始日期", selection: $range.start, in: ...Date(), displayedComponents: .date)
                                .accessibilityIdentifier("scan.range.start")
                            Divider().overlay(SiftStyle.border)
                            DatePicker("结束日期", selection: $range.end, in: ...Date(), displayedComponents: .date)
                                .accessibilityIdentifier("scan.range.end")
                        }.font(.subheadline).environment(\.locale, Locale(identifier: "zh_CN"))
                            .padding(20).siftPaper()
                        Text("包含开始日与结束日的整天截图。").font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        if loading {
                            HStack(spacing: 12) { ProgressView(); Text("正在统计截图…").font(.subheadline) }
                                .frame(minHeight: 74)
                        } else if let error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        } else if let preview {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(preview.pending)").font(.system(.largeTitle, design: .rounded).weight(.medium)).monospacedDigit()
                                Text("张待扫描").font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                            }.foregroundStyle(SiftStyle.ink).accessibilityElement(children: .combine)
                                .accessibilityIdentifier("scan.range.count")
                            Text(preview.total == 0 ? "这段时间内没有可访问的截图。" : preview.pending == 0 ? "这段时间的截图已经处理过了。" : "共 \(preview.total) 张截图，已处理的会自动跳过。")
                                .font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            if preview.limitedAccess {
                                Label("当前仅统计你授权访问的截图。", systemImage: "lock.shield")
                                    .font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.padding(.horizontal, SiftStyle.pageInset).padding(.bottom, 26)
                    .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }.background(SiftStyle.background).scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        Button {
                            let selectedRange = range
                            dismiss()
                            Task { await store.scanScreenshotAlbum(in: selectedRange) }
                        } label: {
                            HStack {
                                Text("开始扫描")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }.padding(.horizontal, 20)
                        }.buttonStyle(SiftPrimaryButton()).disabled(!canBegin)
                            .accessibilityIdentifier("scan.range.begin")
                        Label("图片和文字只在设备上识别", systemImage: "lock")
                            .font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                    }.padding(.horizontal, SiftStyle.pageInset).padding(.top, 14).padding(.bottom, 12)
                        .frame(maxWidth: 640).frame(maxWidth: .infinity).background(SiftStyle.background)
                }
                .navigationTitle("选择扫描时间").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(SiftStyle.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }.frame(minHeight: 44).accessibilityIdentifier("scan.range.cancel")
                    }
                }
                .task(id: range) {
                    loading = true
                    preview = nil
                    error = nil
                    do {
                        let value = try await store.previewScreenshots(in: range)
                        guard !Task.isCancelled else { return }
                        preview = value
                        previewRange = range
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.error = error.localizedDescription
                    }
                    loading = false
                }
        }.tint(SiftStyle.ink).presentationDragIndicator(.visible)
    }

    private func preset(days: Int, identifier: String) -> some View {
        let selected = isRecent(days: days)
        return Button { range = .recent(days: days) } label: {
            HStack {
                Text("最近 \(days) 天")
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }.font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(selected ? SiftStyle.accentInk : SiftStyle.ink)
                .background(selected ? SiftStyle.accent : SiftStyle.background, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(SiftStyle.border, lineWidth: selected ? 0 : 1))
        }.buttonStyle(SiftPressStyle()).accessibilityIdentifier(identifier)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isRecent(days: Int) -> Bool {
        let recent = ScreenshotDateRange.recent(days: days)
        return Calendar.current.isDate(range.start, inSameDayAs: recent.start) && Calendar.current.isDate(range.end, inSameDayAs: recent.end)
    }
}
