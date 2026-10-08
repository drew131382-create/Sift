import SwiftUI

enum SiftStyle {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }

    static let accent = Color(red: 1, green: 214.0 / 255, blue: 0)
    static let accentInk = Color(red: 23.0 / 255, green: 23.0 / 255, blue: 23.0 / 255)
    static let ink = adaptive(0x222222, 0xF5F5F5)
    static let inverseInk = adaptive(0xFFFFFF, 0x222222)
    static let background = adaptive(0xFFFFFF, 0x161616)
    static let surface = adaptive(0xFFFFFF, 0x222222)
    static let paperShade = adaptive(0xFEFEFC, 0x202020)
    static let secondaryInk = adaptive(0x686868, 0xB6B6B6)
    static let blush = accent
    static let border = adaptive(0x222222, 0xF5F5F5).opacity(0.10)
    static let warning = adaptive(0x765700, 0xFFD600)
    static let radius: CGFloat = 20
    static let pageInset: CGFloat = 22

    static func categoryTint(_ group: CategoryGroup) -> Color { ink }
    static func categorySurface(_ group: CategoryGroup) -> Color { paperShade }

}

extension CategoryGroup {
    var shortTitle: String {
        switch self {
        case .collectionCodes: return "领取"
        case .schedules: return "日程"
        case .purchases: return "消费"
        case .collections: return "收藏"
        case .conversations: return "闲聊"
        }
    }
    var index: String {
        switch self {
        case .collectionCodes: return "01"
        case .schedules: return "02"
        case .purchases: return "03"
        case .collections: return "04"
        case .conversations: return "05"
        }
    }
    var emptyMessage: String {
        switch self {
        case .collectionCodes: return "取件与取餐，随手可取。"
        case .schedules: return "下一次约定，留在这里。"
        case .purchases: return "订单与凭证，有处可寻。"
        case .collections: return "留住一个值得回看的发现。"
        case .conversations: return "把值得回看的对话收在这里。"
        }
    }
}

struct SiftPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .foregroundStyle(isEnabled ? SiftStyle.accentInk : SiftStyle.secondaryInk)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                RoundedRectangle(cornerRadius: 16).fill(isEnabled ? SiftStyle.accent : SiftStyle.border)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(isEnabled ? 0.10 : 0), lineWidth: 1))
                    .shadow(color: .black.opacity(isEnabled ? 0.08 : 0), radius: 3, y: 2)
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct SiftPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SiftMark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("sift").font(.system(size: 28, weight: .bold, design: .rounded)).tracking(-1.8)
            RoundedRectangle(cornerRadius: 2).fill(SiftStyle.accent).frame(width: 8, height: 8)
        }.foregroundStyle(SiftStyle.ink)
            .accessibilityElement(children: .ignore).accessibilityLabel("Sift")
    }
}

struct SiftEyebrow: View {
    let title: String
    var body: some View {
        Text(title).font(.caption.weight(.medium)).tracking(0.6).foregroundStyle(SiftStyle.secondaryInk)
    }
}

struct SiftStateBadge: View {
    let state: ItemState
    var body: some View {
        Label(state.displayName, systemImage: state == .needsReview ? "exclamationmark.circle" : state == .completed ? "checkmark.circle" : state == .archived ? "archivebox" : "circle.dotted")
            .font(.caption.weight(.medium))
            .foregroundStyle(state == .needsReview ? SiftStyle.accentInk : SiftStyle.secondaryInk)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(state == .needsReview ? SiftStyle.blush : SiftStyle.background, in: Capsule())
    }
}

extension View {
    func siftCard() -> some View {
        self.padding(20).siftPaper()
    }
    func siftPaper(radius: CGFloat = SiftStyle.radius) -> some View {
        modifier(SiftPaperSurface(radius: radius))
    }
}

/// A subtle bevel and contact shadow give the cards the weight of paper.
private struct SiftPaperSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [SiftStyle.surface, SiftStyle.paperShade], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.14 : 0.035), radius: 7, y: 3)
                .shadow(color: .black.opacity(0.035), radius: 1, y: 1)
        }.overlay {
            RoundedRectangle(cornerRadius: radius).strokeBorder(SiftStyle.border, lineWidth: 0.5)
                .overlay(RoundedRectangle(cornerRadius: radius - 0.5)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.05 : 0.85), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .padding(0.5))
                .allowsHitTesting(false)
        }
    }
}

struct ScreenshotIllustration: View {
    var body: some View {
        Image(systemName: "square.stack")
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(SiftStyle.accentInk)
            .frame(width: 64, height: 64)
            .background(SiftStyle.accent, in: RoundedRectangle(cornerRadius: 20))
            .rotationEffect(.degrees(-5))
            .dynamicTypeSize(.medium).accessibilityHidden(true)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.headline).foregroundStyle(SiftStyle.ink)
            content
        }.frame(maxWidth: .infinity, alignment: .leading).siftCard()
    }
}

struct SiftDisclosureSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) { content }.padding(.top, 16)
        } label: {
            Text(title).font(.headline).foregroundStyle(SiftStyle.ink).frame(minHeight: 24)
        }.tint(SiftStyle.secondaryInk).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(SiftStyle.border).frame(height: 0.5).allowsHitTesting(false) }
    }
}
