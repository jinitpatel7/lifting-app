import SwiftUI
import UIKit

enum Palette {
    static let purple = adaptive(light: 0x5730C4, dark: 0xD0BAFF)
    static let action = Color(hex: 0x6943DD)
    static let red = adaptive(light: 0xA1324A, dark: 0xFFA6B8)
    static let background = adaptive(light: 0xF6F5FA, dark: 0x131118)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x201D29)
    static let soft = adaptive(light: 0xF7F5FC, dark: 0x272332)
    static let lavender = adaptive(light: 0xEEE8FC, dark: 0x382953)
    static let border = adaptive(light: 0xE9E5F0, dark: 0x3A3348)
    static let muted = adaptive(light: 0x625C70, dark: 0xBCB4CB)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension View {
    func surface(radius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(Palette.surface, in: shape)
            .overlay { shape.strokeBorder(Palette.border, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(subtitle.uppercased())
                .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Palette.purple)
            Text(title).font(.largeTitle.weight(.heavy)).accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CardHeading: View {
    let title: String

    var body: some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }
}

struct IconTile: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Palette.purple)
            .frame(width: size, height: size)
            .background(Palette.lavender, in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .foregroundStyle(.white)
            .background(Palette.action.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(Palette.purple)
            .background(Palette.lavender.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct BundleImage: View {
    let file: String
    var contentMode: ContentMode = .fit

    private var image: UIImage? {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).accessibilityHidden(true)
        }
    }
}

struct GlassSurface: View {
    let opaque: Bool
    var radius: CGFloat = 21

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        shape.fill(Palette.surface.opacity(opaque ? 1 : 0.5))
            .background {
                if !opaque { shape.fill(.ultraThinMaterial) }
            }
            .overlay { shape.strokeBorder(Palette.border, lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
            .allowsHitTesting(false)
    }
}
