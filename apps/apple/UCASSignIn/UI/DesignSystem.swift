import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Palette {
    static let background = Color(light: 0xF6F7F2, dark: 0x111A16)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1D2922)
    static let ink = Color(light: 0x1C342B, dark: 0xEDF3ED)
    static let secondary = Color(light: 0x7B8780, dark: 0xA0ADA4)
    static let green = Color(light: 0x285C45, dark: 0x91C6A6)
    static let pale = Color(light: 0xE8EFE4, dark: 0x2C4234)
    static let line = Color(light: 0xE4E9E0, dark: 0x344039)
    static let accent = Color(red: 0.79, green: 0.90, blue: 0.61)
    static let hero = Color(red: 0.12, green: 0.28, blue: 0.21)
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
        #endif
    }
}

struct PrimaryButton: View {
    var title: String
    var symbol: String = "arrow.right"
    var loading = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if loading { ProgressView().tint(.white) }
                Text(title).font(.system(size: 16, weight: .semibold))
                if !loading { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundStyle(.white).background(Palette.hero, in: RoundedRectangle(cornerRadius: 17))
        }.buttonStyle(.plain).disabled(loading)
    }
}

struct StatusPill: View {
    var title: String
    var symbol: String? = nil
    var tint: Color = Palette.green
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }.font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint).padding(.horizontal, 9).padding(.vertical, 5)
            .background(tint.opacity(0.08), in: Capsule())
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.ink)
            Spacer()
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
        }
    }
}

enum SchoolDate {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2
        return value
    }
    static func text(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    static func key(_ date: Date) -> String { text(date, "yyyyMMdd") }
    static func week(containing date: Date) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

extension View {
    func cardSurface() -> some View {
        self.background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}
