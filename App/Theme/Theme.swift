import SwiftUI
import UIKit

/// 冷色设计规范（定稿 v1）：白底 / #171719 主字 / #2F6BFF 强调 / #F2F3F5 胶囊。
enum ZTheme {
    static let accent = Color(red: 0.184, green: 0.42, blue: 1.0)            // #2F6BFF
    static let accentWeak = Color(red: 0.918, green: 0.941, blue: 1.0)       // #EAF0FF
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.098)              // #171719
    static let inkSoft = Color(red: 0.541, green: 0.561, blue: 0.596)        // #8A8F98
    static let inkFaint = Color(red: 0.702, green: 0.722, blue: 0.761)       // #B3B8C2
    static let chip = Color(red: 0.949, green: 0.953, blue: 0.961)           // #F2F3F5
    static let surface = Color(red: 0.969, green: 0.969, blue: 0.973)        // #F7F7F8
    static let line = Color(red: 0.925, green: 0.925, blue: 0.933)           // #ECECEE
    static let ok = Color(red: 0.133, green: 0.627, blue: 0.42)              // #22A06B
    static let okBg = Color(red: 0.910, green: 0.965, blue: 0.937)
    static let danger = Color(red: 0.898, green: 0.282, blue: 0.302)         // #E5484D
    static let dangerBg = Color(red: 0.992, green: 0.922, blue: 0.925)

    static var canvas: Color { Color(uiColor: .systemBackground) }

    static func statusBadge(_ status: String) -> (text: String, fg: Color, bg: Color) {
        switch status {
        case "running", "waiting": return ("运行中", accent, accentWeak)
        case "completed": return ("已完成", ok, okBg)
        case "error": return ("出错", danger, dangerBg)
        default: return ("空闲", inkSoft, chip)
        }
    }
}

enum ZUIColor {
    static func accent(_ t: UITraitCollection) -> UIColor {
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.098, green: 0.557, blue: 1.0, alpha: 1)
            : UIColor(red: 0.184, green: 0.42, blue: 1.0, alpha: 1)
    }
    static func ink(_ t: UITraitCollection) -> UIColor {
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.949, green: 0.953, blue: 0.961, alpha: 1)
            : UIColor(red: 0.09, green: 0.09, blue: 0.098, alpha: 1)
    }
    static func inkSoft(_ t: UITraitCollection) -> UIColor {
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.60, green: 0.62, blue: 0.66, alpha: 1)
            : UIColor(red: 0.541, green: 0.561, blue: 0.596, alpha: 1)
    }
    static func inkFaint(_ t: UITraitCollection) -> UIColor {
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.46, blue: 0.49, alpha: 1)
            : UIColor(red: 0.702, green: 0.722, blue: 0.761, alpha: 1)
    }
    static func chip(_ t: UITraitCollection) -> UIColor {
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.137, green: 0.141, blue: 0.157, alpha: 1)   // #232428
            : UIColor(red: 0.949, green: 0.953, blue: 0.961, alpha: 1)
    }
    static func surface(_ t: UITraitCollection) -> UIColor {
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.114, blue: 0.129, alpha: 1)    // #1C1D21
            : UIColor(red: 0.969, green: 0.969, blue: 0.973, alpha: 1)
    }
    static func line(_ t: UITraitCollection) -> UIColor {
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.165, green: 0.169, blue: 0.188, alpha: 1)   // #2A2B30
            : UIColor(red: 0.925, green: 0.925, blue: 0.933, alpha: 1)
    }
    static func canvas(_ t: UITraitCollection) -> UIColor {
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1)   // #111214
            : .white
    }
    static let ok = UIColor(red: 0.133, green: 0.627, blue: 0.42, alpha: 1)
    static let danger = UIColor(red: 0.898, green: 0.282, blue: 0.302, alpha: 1)
}

struct PressScaleStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum TimeFormat {
    static func relative(_ ms: Int, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let sec = Int(now.timeIntervalSince(date))
        if sec < 60 { return "刚刚" }
        if sec < 3600 { return "\(sec / 60)分" }
        if sec < 86400 { return "\(sec / 3600)小时" }
        return "\(sec / 86400)天"
    }

    static func clock(_ ms: Int) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func duration(seconds: Int) -> String {
        if seconds < 60 { return "\(max(1, seconds)) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds / 3600) 小时 \((seconds % 3600) / 60) 分"
    }
}
