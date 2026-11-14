import SwiftUI
import UIKit

/// Look of the app. Started as direction "Sumi" (warm near-black, paper-white
/// text, vermilion accent, serif titles). After feedback from Rev ("too square,
/// too empty") it keeps that palette but uses rounded cards, pills, banners
/// with cover art and bold rounded headings. Dark only.
/// Kept cheap for the A8X: flat fills and gradients, no blur, no shadows on
/// scrolling cells.
enum Theme {
    static let background = Color(red: 0x13 / 255, green: 0x12 / 255, blue: 0x11 / 255)
    static let surface = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x19 / 255)
    static let line = Color(red: 0x3A / 255, green: 0x37 / 255, blue: 0x33 / 255)
    static let text = Color(red: 0xEC / 255, green: 0xE6 / 255, blue: 0xDA / 255)
    static let muted = Color(red: 0x9A / 255, green: 0x94 / 255, blue: 0x88 / 255)
    static let accent = Color(red: 0xD2 / 255, green: 0x45 / 255, blue: 0x2A / 255)
    /// Slightly lighter card colour, for cards sitting on other cards and for pills.
    static let raised = Color(red: 0x29 / 255, green: 0x27 / 255, blue: 0x24 / 255)
    /// Tinted background for selected or highlighted things.
    static let accentSoft = Color(red: 0xD2 / 255, green: 0x45 / 255, blue: 0x2A / 255).opacity(0.18)
    /// Second colour, used sparingly (progress, numbers).
    static let gold = Color(red: 0xE3 / 255, green: 0xB3 / 255, blue: 0x5A / 255)

    /// Corner sizes. Rounded shapes everywhere (cards, covers, buttons, pills).
    static let radius: CGFloat = 18
    static let coverRadius: CGFloat = 12

    /// Bold rounded face for section headings and buttons.
    static func heading(_ style: Font.TextStyle) -> Font {
        .system(style, design: .rounded).weight(.bold)
    }

    static func card(_ radius: CGFloat = Theme.radius) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    static let uiBackground = UIColor(red: 0x13 / 255, green: 0x12 / 255, blue: 0x11 / 255, alpha: 1)
    static let uiText = UIColor(red: 0xEC / 255, green: 0xE6 / 255, blue: 0xDA / 255, alpha: 1)
    static let uiMuted = UIColor(red: 0x9A / 255, green: 0x94 / 255, blue: 0x88 / 255, alpha: 1)
    static let uiAccent = UIColor(red: 0xD2 / 255, green: 0x45 / 255, blue: 0x2A / 255, alpha: 1)

    /// Serif face for titles (the system's "New York"). Follows Dynamic Type.
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }

    private static func uiSerif(_ style: UIFont.TextStyle, bold: Bool) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        if bold { descriptor = descriptor.withSymbolicTraits(.traitBold) ?? descriptor }
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// Styles the UIKit bars and lists once at launch.
    static func apply() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiBackground
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: uiText, .font: uiSerif(.headline, bold: true)]
        nav.largeTitleTextAttributes = [.foregroundColor: uiText, .font: uiSerif(.largeTitle, bold: false)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = uiAccent

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = uiBackground
        // Do NOT set title text attributes here: on iPad they make the tab
        // labels truncate ("Libr..."). Tint colours do the same job safely.
        UITabBar.appearance().tintColor = uiText
        UITabBar.appearance().unselectedItemTintColor = uiMuted
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        // SwiftUI lists are table views on iOS 15; make them show our background.
        UITableView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear
    }
}

/// Small pill label, e.g. an unread count.
struct Seal: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent))
    }
}

/// Pill used for genres, filters and choices.
struct Chip: View {
    let text: String
    var selected = false
    var body: some View {
        Text(text)
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundColor(selected ? .white : Theme.text)
            .padding(.horizontal, 16)
            .frame(minHeight: 38)
            .background(Capsule().fill(selected ? Theme.accent : Theme.raised))
    }
}

/// Filled, rounded main button.
struct PrimaryLabel: View {
    let text: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 8) {
            if let symbol = symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(Theme.heading(.subheadline))
        .foregroundColor(.white)
        .padding(.horizontal, 22)
        .frame(minHeight: 46)
        .background(Capsule().fill(Theme.accent))
    }
}

/// Section title with an optional note under it and an optional trailing view.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.heading(.title2)).foregroundColor(Theme.text)
                if let note = note {
                    Text(note).font(.footnote).foregroundColor(Theme.muted)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, note: String? = nil) {
        self.init(title: title, note: note, trailing: { EmptyView() })
    }
}

/// Wide banner: the cover fills the background (enlarged, so it reads as
/// soft artwork without any blur effect), darkened by a gradient, with text
/// on the left and the sharp cover on the right.
struct HeroBanner<Extra: View>: View {
    let runtime: SourceRuntime
    let cover: String?
    let eyebrow: String
    let title: String
    let detail: String
    let button: String
    var symbol: String = "play.fill"
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { box in
                RemoteImage(runtime: runtime, url: cover, maxPixel: 500)
                    .frame(width: box.size.width, height: box.size.height)
                    .clipped()
            }
            LinearGradient(colors: [Theme.background.opacity(0.97), Theme.background.opacity(0.82), Theme.background.opacity(0.35)],
                           startPoint: .leading, endPoint: .trailing)
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(eyebrow)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.accent))
                    Text(title)
                        .font(Theme.serif(.largeTitle, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail).font(.callout).foregroundColor(Theme.text.opacity(0.8)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    extra()
                    PrimaryLabel(text: button, symbol: symbol).padding(.top, 4)
                }
                Spacer(minLength: 0)
                RemoteImage(runtime: runtime, url: cover, maxPixel: 600)
                    .frame(width: 150, height: 225)
                    .clipShape(Theme.card(Theme.coverRadius))
                    .overlay(Theme.card(Theme.coverRadius).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .padding(24)
        }
        .frame(height: 285)
        .clipShape(Theme.card(24))
        .padding(.horizontal, 20)
    }
}

extension HeroBanner where Extra == EmptyView {
    init(runtime: SourceRuntime, cover: String?, eyebrow: String, title: String, detail: String, button: String, symbol: String = "play.fill") {
        self.init(runtime: runtime, cover: cover, eyebrow: eyebrow, title: title, detail: detail, button: button, symbol: symbol, extra: { EmptyView() })
    }
}

/// Thin rounded progress line.
struct ProgressLine: View {
    let fraction: Double
    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(Theme.gold).frame(width: max(0, min(1, fraction)) * box.size.width)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
