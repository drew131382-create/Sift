import SwiftUI

struct ReprocessingEntry: Identifiable {
    var item: InformationItem?
    var job: ProcessingJob?
    var id: UUID { item?.id ?? job!.id }
    var createdAt: Date { item?.createdAt ?? job?.createdAt ?? .distantPast }
}

struct ReprocessingView: View {
    @EnvironmentObject private var store: SiftStore
    @State private var screenshotURL: URL?
    @State private var showingScreenshot = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if store.reprocessingEntries.isEmpty {
                    ContentUnavailableView("没有需要重新处理的截图", systemImage: "checkmark.circle", description: Text("识别完整的信息会直接显示在首页。"))
                }
                ForEach(store.reprocessingEntries) { entry in
                    entryView(entry)
                }
            }.padding(SiftStyle.pageInset).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(SiftStyle.background).navigationTitle("重新处理")
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .fullScreenCover(isPresented: $showingScreenshot) { ScreenshotViewer(url: screenshotURL, title: "原始截图") }
    }

    private func entryView(_ entry: ReprocessingEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry.item?.title ?? "尚未识别的截图").font(.headline)
                Spacer()
                Button {
                    screenshotURL = entry.item.flatMap { store.imageURL($0) } ?? entry.job.flatMap { store.imageURL($0) }
                    showingScreenshot = true
                } label: {
                    Group {
                        if let image = entry.item.flatMap({ store.thumbnail($0) }) ?? entry.job.flatMap({ store.thumbnail($0) }) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).background(SiftStyle.background) }
                    }.frame(width: 64, height: 84).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                }
                    .accessibilityLabel("查看原图").accessibilityIdentifier("reprocessing.\(entry.id.uuidString).image")
            }
            if let job = entry.job {
                Text(job.errorMessage ?? job.state.displayName).font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
            }
            ForEach(entry.item?.reprocessingReasons ?? []) { reason in
                Text(reason.detail).font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
            }
            HStack(spacing: 16) {
                Button("重新识别") {
                    Task {
                        if let job = entry.job { await store.retry(job) }
                        else if let item = entry.item { await store.retry(item) }
                    }
                }.disabled(store.busy || (entry.job != nil && entry.job?.state != .failed))
                    .accessibilityIdentifier("reprocessing.\(entry.id.uuidString).retry")
                if let item = entry.item {
                    NavigationLink("编辑信息") { DetailView(item: item) }
                        .disabled(entry.job != nil && entry.job?.state != .failed)
                        .accessibilityIdentifier("reprocessing.\(entry.id.uuidString).edit")
                } else if let job = entry.job {
                    NavigationLink("编辑信息") { DetailView(item: store.editableItem(for: job)) }
                        .disabled(job.state != .failed)
                        .accessibilityIdentifier("reprocessing.\(entry.id.uuidString).edit")
                }
            }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }.foregroundStyle(SiftStyle.ink).padding(18).siftPaper()
    }
}
