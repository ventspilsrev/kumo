import SwiftUI
import UIKit

/// Design direction "Sumi": warm near-black, paper-white text, one vermilion
/// accent, serif titles. Dark only.
enum Theme {
    static let background = Color(red: 0x13 / 255, green: 0x12 / 255, blue: 0x11 / 255)
    static let surface = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x19 / 255)
    static let line = Color(red: 0x3A / 255, green: 0x37 / 255, blue: 0x33 / 255)
    static let text = Color(red: 0xEC / 255, green: 0xE6 / 255, blue: 0xDA / 255)
    static let muted = Color(red: 0x9A / 255, green: 0x94 / 255, blue: 0x88 / 255)
    static let accent = Color(red: 0xD2 / 255, green: 0x45 / 255, blue: 0x2A / 255)

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
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = uiMuted
            item.normal.titleTextAttributes = [.foregroundColor: uiMuted]
            item.selected.iconColor = uiText
            item.selected.titleTextAttributes = [.foregroundColor: uiText]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        // SwiftUI lists are table views on iOS 15; make them show our background.
        UITableView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear
    }
}

/// Small rectangular label, e.g. an unread count.
struct Seal: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accent)
    }
}

/// Outlined choice chip used for genres and filters.
struct Chip: View {
    let text: String
    var selected = false
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(selected ? Theme.background : Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Theme.text : Color.clear)
            .overlay(Rectangle().stroke(selected ? Theme.text : Theme.line, lineWidth: 1))
    }
}
