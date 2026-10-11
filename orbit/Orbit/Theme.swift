import SwiftUI
import UniformTypeIdentifiers

/// Categorical palette for spaces and mindmap branches, validated for colour-vision deficiency on light and dark
/// surfaces. Slots are assigned in this fixed order.
enum Palette {
    private static let light: [UInt32] = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x6250d6, 0xe34948]
    private static let dark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767]
    static let count = light.count
    static func color(_ slot: Int) -> Color { Color(light: light[slot % count], dark: dark[slot % count]) }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255, CGFloat(hex & 0xff) / 255)
        }
        let (l, d) = (rgb(light), rgb(dark))
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }
}

extension Space {
    var color: Color { Palette.color(tone) }
}

extension Item {
    var symbol: String {
        guard kind == .file, let type = file.flatMap({ UTType($0.type) }) else { return kind.icon }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .audio) { return "play.rectangle" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .json) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .archive) { return "archivebox" }
        return "doc"
    }
}

/// Tinted rounded square with a symbol, used for kinds and spaces.
struct Glyph: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .rect(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// File thumbnail (decrypted lazily, cached) or the kind glyph.
struct Thumb: View {
    @Environment(Store.self) private var store
    let item: Item
    var size: CGFloat = 34
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size * 0.24, style: .continuous))
            } else {
                Glyph(symbol: item.symbol, tint: item.kind.tint, size: size)
            }
        }
        .task(id: item.id) {
            if item.file?.hasThumb == true { image = await store.thumbnail(item.id) }
        }
    }
}

struct TagChip: View {
    var text: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text("#" + text)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.7), in: .capsule)
    }
}

struct SpaceTag: View {
    let space: Space

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(space.color).frame(width: 7, height: 7)
            Text(space.name)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

/// A content card on the quiet layer (Liquid Glass is reserved for floating controls).
struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

/// Lifts a view slightly under the pointer.
struct HoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: 12, y: 6)
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.2), value: hovering)
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

/// Horizontal shake for rejected input.
struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Deep-space mesh used behind the lock screen and the overview header.
struct OrbitBackground: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.62, 0.42], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.07, green: 0.06, blue: 0.19), Color(red: 0.16, green: 0.10, blue: 0.40), Color(red: 0.05, green: 0.10, blue: 0.26),
            Color(red: 0.12, green: 0.08, blue: 0.33), Color(red: 0.30, green: 0.20, blue: 0.70), Color(red: 0.05, green: 0.32, blue: 0.55),
            Color(red: 0.05, green: 0.05, blue: 0.14), Color(red: 0.10, green: 0.14, blue: 0.36), Color(red: 0.03, green: 0.30, blue: 0.48),
        ])
        .ignoresSafeArea()
    }
}

/// The app mark: a glowing core with a satellite on a tilted orbit.
struct OrbitMark: View {
    @State private var spin = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Color(red: 0.55, green: 0.45, blue: 1).opacity(0.45)).blur(radius: s * 0.18).frame(width: s * 0.6)
                ZStack {
                    Circle().stroke(.white.opacity(0.85), lineWidth: s * 0.03)
                    Circle().fill(Color(red: 0.66, green: 0.92, blue: 1)).frame(width: s * 0.09)
                        .shadow(color: .cyan, radius: s * 0.06)
                        .offset(y: -s * 0.45)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                }
                .frame(width: s * 0.9, height: s * 0.9)
                .scaleEffect(x: 1, y: 0.42)
                .rotationEffect(.degrees(-24))
                Circle()
                    .fill(RadialGradient(colors: [.white, Color(red: 0.62, green: 0.66, blue: 1)], center: .init(x: 0.35, y: 0.3),
                                         startRadius: 0, endRadius: s * 0.3))
                    .frame(width: s * 0.36)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) { spin = true } }
    }
}

struct NoticeView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "sparkle")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
    }
}
