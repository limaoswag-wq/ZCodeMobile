import SwiftUI
import UIKit

enum ZTheme {
    static let cardRadius: CGFloat = 24
    static let pillRadius: CGFloat = 22
    static let bubbleRadius: CGFloat = 20
    static let iconButton: CGFloat = 44
    static let ease = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.22)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    static let canvasLight = Color(red: 0.973, green: 0.949, blue: 0.910)
    static let canvasDark = Color(red: 0.16, green: 0.13, blue: 0.10)
    static let cream = Color(red: 0.988, green: 0.965, blue: 0.933)
    static let ink = Color(red: 0.42, green: 0.24, blue: 0.14)
    static let inkSoft = Color(red: 0.45, green: 0.33, blue: 0.24)
    static let accent = Color(red: 0.78, green: 0.48, blue: 0.29)
    static let accentDeep = Color(red: 0.55, green: 0.29, blue: 0.16)
    static let wash = Color(red: 0.93, green: 0.82, blue: 0.66).opacity(0.38)
    static let line = Color.white.opacity(0.46)

    static var canvas: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1)
                : UIColor(red: 0.973, green: 0.949, blue: 0.910, alpha: 1)
        })
    }
}

enum ZUIColor {
    static let canvasLight = UIColor(red: 0.973, green: 0.949, blue: 0.910, alpha: 1)
    static let canvasDark = UIColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1)
    static let cream = UIColor(red: 0.988, green: 0.965, blue: 0.933, alpha: 1)
    static let creamDark = UIColor(red: 0.22, green: 0.18, blue: 0.14, alpha: 1)
    static let ink = UIColor(red: 0.42, green: 0.24, blue: 0.14, alpha: 1)
    static let inkDark = UIColor(red: 0.96, green: 0.92, blue: 0.86, alpha: 1)
    static let accent = UIColor(red: 0.78, green: 0.48, blue: 0.29, alpha: 1)
    static let accentDeep = UIColor(red: 0.55, green: 0.29, blue: 0.16, alpha: 1)
    static let userBubble = UIColor(red: 0.78, green: 0.48, blue: 0.29, alpha: 1)
    static let assistantBubbleLight = UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1)
    static let assistantBubbleDark = UIColor(red: 0.24, green: 0.19, blue: 0.15, alpha: 1)
    static let codeBgLight = UIColor(red: 0.95, green: 0.91, blue: 0.85, alpha: 1)
    static let codeBgDark = UIColor(red: 0.12, green: 0.10, blue: 0.08, alpha: 1)

    static func canvas(_ trait: UITraitCollection) -> UIColor {
        trait.userInterfaceStyle == .dark ? canvasDark : canvasLight
    }

    static func ink(_ trait: UITraitCollection) -> UIColor {
        trait.userInterfaceStyle == .dark ? inkDark : ink
    }

    static func assistantBubble(_ trait: UITraitCollection) -> UIColor {
        trait.userInterfaceStyle == .dark ? assistantBubbleDark : assistantBubbleLight
    }

    static func creamCard(_ trait: UITraitCollection) -> UIColor {
        trait.userInterfaceStyle == .dark ? creamDark : cream
    }
}

struct PressScaleStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(ZTheme.ease, value: configuration.isPressed)
    }
}

struct RoundIconButton: View {
    let systemName: String
    var size: CGFloat = ZTheme.iconButton
    var fill: Color = ZTheme.cream
    var ink: Color = ZTheme.ink
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(fill)
                .clipShape(Circle())
                .overlay(Circle().stroke(ZTheme.line, lineWidth: 0.7))
                .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PillButton: View {
    let title: String
    var systemName: String? = nil
    var filled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(filled ? Color.white : ZTheme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(filled ? ZTheme.accent : ZTheme.cream)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(ZTheme.line, lineWidth: 0.7))
            .shadow(color: Color.black.opacity(filled ? 0.12 : 0.05), radius: 12, y: 5)
        }
        .buttonStyle(PressScaleStyle())
    }
}
