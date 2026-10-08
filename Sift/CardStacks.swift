import SwiftUI

struct CardStackSection: View {
    let group: CategoryGroup
    let items: [InformationItem]
    let expanded: Bool
    var automaticExpansion: Bool = false
    var toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || PreviewLaunchOptions.reduceMotion }
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var stackSpace
    @State private var visualExpanded = false
    @State private var moving = false
    @State private var motionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                toggle()
            } label: {
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment:.leading,spacing:8) {
                            groupLabel
                            HStack { itemCount; Spacer(minLength:0); expansionLabel }
                        }
                    } else {
                        HStack(spacing:12) { groupLabel; itemCount; Spacer(minLength:0); expansionLabel }
                    }
                }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(SiftPressStyle()).disabled(items.isEmpty)
                .accessibilityLabel("\(group.displayName)，\(items.count) 条，\(expanded ? "收起" : "展开")")
                .accessibilityHint("显示或收起这一类的全部信息卡")
                .accessibilityIdentifier("stack.\(group.rawValue).toggle")

            if items.isEmpty {
                Text("暂无\(group.shortTitle)信息").font(.subheadline).foregroundStyle(SiftStyle.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
            } else if let first = items.first {
                VStack(spacing: 14) {
                    SiftItemCard(item: first)
                        .matchedGeometryEffect(id: first.id, in: stackSpace)
                        .zIndex(3)
                        .background(alignment: .bottom) {
                            if !visualExpanded {
                                ForEach(Array(items.prefix(3).dropFirst().enumerated()), id: \.element.id) { offset, item in
                                    let layer = offset + 1
                                    RoundedRectangle(cornerRadius: SiftStyle.radius)
                                        .fill(layer == 1 ? SiftStyle.accent : SiftStyle.surface)
                                        .overlay(RoundedRectangle(cornerRadius: SiftStyle.radius).strokeBorder(SiftStyle.border, lineWidth: 1))
                                        .padding(.horizontal, CGFloat(layer * 6))
                                        .rotationEffect(.degrees(reduceMotion ? 0 : layer == 1 ? 1.5 : -2), anchor: .bottom)
                                        .offset(y: CGFloat(layer * 16))
                                        .shadow(color: .black.opacity(0.05), radius: 5, y: 3)
                                        .matchedGeometryEffect(id: item.id, in: stackSpace)
                                        .zIndex(Double(-layer))
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                        }
                        .padding(.bottom, visualExpanded ? 0 : CGFloat(min(items.count - 1, 2) * 16 + (items.count > 1 ? 4 : 0)))
                    if visualExpanded {
                        LazyVStack(spacing: 14) {
                            ForEach(Array(items.dropFirst().enumerated()), id: \.element.id) { index, item in
                                if index < 2 {
                                    SiftItemCard(item: item)
                                        .matchedGeometryEffect(id: item.id, in: stackSpace)
                                        .transition(cardTransition(index: index))
                                        .animation(stackAnimation(delay: Double(index + 1) * 0.05), value: visualExpanded)
                                } else {
                                    SiftItemCard(item: item)
                                        .transition(reduceMotion || automaticExpansion ? .opacity : .opacity.combined(with: .offset(y: -12)))
                                }
                            }
                        }
                    }
                }.allowsHitTesting(!moving).disabled(moving)
            }
        }.accessibilityElement(children: .contain)
            .onAppear { visualExpanded = expanded }
            .onChange(of: expanded) { _, value in setExpansion(value) }
            .onChange(of: automaticExpansion) { _, _ in setExpansion(expanded) }
            .onDisappear { motionTask?.cancel(); moving = false }
    }

    private func stackAnimation(delay: Double = 0) -> Animation? {
        if automaticExpansion { return nil }
        return reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.84).delay(delay)
    }
    private func cardTransition(index: Int) -> AnyTransition {
        if reduceMotion || automaticExpansion { return .opacity }
        return .modifier(active: StackCardPose(rotation: index == 0 ? 1.5 : -2, scale: 0.97, lift: -16),
                         identity: StackCardPose(rotation: 0, scale: 1, lift: 0)).combined(with: .opacity)
    }
    private func setExpansion(_ value: Bool) {
        motionTask?.cancel()
        moving = !automaticExpansion
        withAnimation(stackAnimation()) { visualExpanded = value }
        guard !automaticExpansion else { moving = false; return }
        motionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 160 : 650))
            guard !Task.isCancelled else { return }
            moving = false
        }
    }
    private var groupLabel: some View {
        Label(group.shortTitle,systemImage:group.symbol)
            .font(.subheadline.weight(.semibold)).foregroundStyle(SiftStyle.accentInk)
            .padding(.horizontal,14).padding(.vertical,typeSize.isAccessibilitySize ? 8 : 0)
            .frame(minHeight:40).background(SiftStyle.accent,in:RoundedRectangle(cornerRadius:12))
    }
    private var itemCount: some View {
        Text("\(items.count) 张").font(.caption.monospacedDigit()).foregroundStyle(SiftStyle.secondaryInk)
    }
    @ViewBuilder private var expansionLabel: some View {
        if !items.isEmpty {
            HStack(spacing:5) {
                Text(expanded ? "收起" : "展开").font(.caption)
                Image(systemName:expanded ? "chevron.up" : "chevron.down").font(.system(size:10,weight:.semibold))
            }.foregroundStyle(SiftStyle.secondaryInk)
        }
    }

}

private struct StackCardPose: ViewModifier {
    var rotation: Double
    var scale: CGFloat
    var lift: CGFloat
    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(rotation), anchor: .top)
            .scaleEffect(scale, anchor: .top).offset(y: lift)
            .shadow(color: .black.opacity(lift == 0 ? 0 : 0.06), radius: lift == 0 ? 0 : 8, y: 3)
    }
}

struct SiftItemCard: View {
    @EnvironmentObject private var store: SiftStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: InformationItem
    @State private var showingScreenshot = false
    private var group: CategoryGroup { item.category.group }

    private var slots: [CategoryCardField] {
        switch group {
        case .collectionCodes:
            return [CategoryCardField(label: item.category == .pickup ? "取餐码" : "取件码", source: .fields(primary: .code, fallbacks: [])),
                    CategoryCardField(label: "门店 / 驿站", source: .fields(primary: .parcelStation, fallbacks: [.venue, .merchant, .location])),
                    CategoryCardField(label: "截止时间", source: .fields(primary: .deadline, fallbacks: []))]
        case .schedules: return item.category.cardFields + [CategoryCardField(label: "地点", source: .fields(primary: .location, fallbacks: [.venue, .address]))]
        case .purchases:
            var fields = item.category == .shopping && item.contentNature != nil ? [CategoryCardField(label: "商品名称", source: .fields(primary: .product, fallbacks: [])), CategoryCardField(label: "实付金额", source: .fields(primary: .amount, fallbacks: []))] : item.category.cardFields
            if !fields.contains(where: { $0.editableKind == .amount }),
               !item.amount.isEmpty || item.fields.contains(where: { $0.kind == .amount && !$0.value.isEmpty }) {
                fields.append(CategoryCardField(label: "实付金额", source: .fields(primary: .amount, fallbacks: [])))
            }
            return fields + [CategoryCardField(label: "订单状态", source: .fields(primary: .orderStatus, fallbacks: []))]
        case .collections:
            return item.category.cardFields + [CategoryCardField(label: "参考价", source: .fields(primary: .price, fallbacks: []))]
        case .conversations: return item.category.cardFields
        }
    }

    private var emphasis: CategoryCardField? {
        switch group {
        case .collectionCodes: return slots.first { $0.editableKind == .code }
        case .schedules: return slots.first { $0.source == .eventDateTime || $0.editableKind == .date || $0.editableKind == .eventTime }
        case .purchases: return slots.first { $0.editableKind == .amount } ?? slots.first { $0.editableKind == .price }
        case .collections, .conversations: return nil
        }
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) { details; imageButton }
            } else {
                HStack(alignment: .top, spacing: 16) { imageButton.frame(width: 76); details }
            }
        }.padding(18).siftPaper()
            .fullScreenCover(isPresented: $showingScreenshot) { ScreenshotViewer(url: store.imageURL(item), title: item.title) }
    }

    private var imageButton: some View {
        Button { showingScreenshot = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                if let image = store.thumbnail(item) {
                    GeometryReader { proxy in
                        Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    }
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(SiftStyle.secondaryInk)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(SiftStyle.background)
                }
            }.frame(height: typeSize.isAccessibilitySize ? 160 : 104)
                .clipShape(RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(SiftPressStyle())
            .accessibilityLabel("查看\(item.title)的原始截图")
            .accessibilityHint("打开原图，可缩放查看")
            .accessibilityIdentifier("card.\(item.id.uuidString).image")
    }

    /// Show only the most useful context here; the detail screen retains every field.
    private var supportingFields: [CategoryCardField] {
        var seen = Set<String>()
        return Array(slots.filter { slot in
            guard slot.id != emphasis?.id, slot.source != .title,
                  let value = item.cardValue(for: slot), value != item.title,
                  seen.insert(value).inserted else { return false }
            return true
        }.prefix(2))
    }

    private var details: some View {
        NavigationLink { DetailView(item: item) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title).font(.headline).foregroundStyle(SiftStyle.ink)
                        .multilineTextAlignment(.leading).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SiftStyle.secondaryInk).accessibilityHidden(true)
                }
                if item.category == .social || item.category == .other {
                    Text("历史未分类").font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                }
                if let emphasis {
                    if let value = item.cardValue(for: emphasis) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(emphasis.label).font(.caption).foregroundStyle(SiftStyle.secondaryInk)
                            Text(value).font(emphasis.editableKind == .code || group == .purchases ? .system(.title2, design: .rounded).weight(.semibold) : .headline)
                                .monospacedDigit().foregroundStyle(emphasis.editableKind == .code ? SiftStyle.accentInk : SiftStyle.ink)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, emphasis.editableKind == .code ? 9 : 0)
                                .padding(.vertical, emphasis.editableKind == .code ? 4 : 0)
                                .background(emphasis.editableKind == .code ? SiftStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else if emphasis.editableKind == .code {
                        Label("未识别到号码", systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(SiftStyle.warning)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(supportingFields) { slot in
                        if let value = item.cardValue(for: slot) {
                            Text(slot.editableKind == .deadline ? "截止 \(value)" : slot.editableKind == .price && group == .collections ? "参考价 \(value)" : value)
                                .font(.footnote).foregroundStyle(SiftStyle.secondaryInk)
                                .multilineTextAlignment(.leading).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if item.state != .pending {
                    SiftStateBadge(state: item.state)
                }
            }.frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading).contentShape(Rectangle())
        }.buttonStyle(SiftPressStyle())
            .accessibilityIdentifier("card.\(item.id.uuidString).details")
    }
}
