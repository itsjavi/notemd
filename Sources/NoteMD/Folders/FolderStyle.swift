import NoteMDCore
import SwiftUI

extension FolderColor {
    var color: Color {
        switch self {
        case .red: Color(hex: 0xE5534B)
        case .orange: Color(hex: 0xEE7D4B)
        case .amber: Color(hex: 0xE9A23B)
        case .yellow: Color(hex: 0xD6BC2E)
        case .lime: Color(hex: 0x86C84A)
        case .green: Color(hex: 0x3FAE6A)
        case .mint: Color(hex: 0x45C4A0)
        case .teal: Color(hex: 0x24A8A6)
        case .cyan: Color(hex: 0x3BA3D6)
        case .blue: Color(hex: 0x3C7FF0)
        case .indigo: Color(hex: 0x5B69E0)
        case .purple: Color(hex: 0x9659DE)
        case .pink: Color(hex: 0xDE5AA2)
        case .silver: Color(hex: 0xB9BEC5)
        case .gray: Color(hex: 0x8E949B)
        case .graphite: Color(hex: 0x62676D)
        case .charcoal: Color(hex: 0x3A3E43)
        }
    }

    var displayName: String { rawValue.capitalized }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum FolderIcons {
    static let defaultIcon = "folder.fill"

    /// Curated SF Symbols offered for folders.
    static let all: [String] = [
        "folder.fill", "briefcase.fill", "house.fill", "person.fill", "person.2.fill", "building.2.fill", "graduationcap.fill", "flask.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "paintbrush.pointed.fill", "gamecontroller.fill", "globe", "server.rack", "iphone", "desktopcomputer",
        "cart.fill", "heart.fill", "star.fill", "bolt.fill", "leaf.fill", "sparkles", "archivebox.fill", "tray.fill",
        "pawprint.fill", "tortoise.fill", "ladybug.fill", "fish.fill", "bird.fill", "tree.fill", "flame.fill", "drop.fill",
        "music.note", "film.fill", "camera.fill", "book.fill", "puzzlepiece.fill", "cube.fill", "cpu.fill", "brain.head.profile",
        "cloud.fill", "shield.fill", "lock.fill", "chart.bar.fill", "map.fill", "airplane", "car.fill", "dollarsign.circle.fill",
        "doc.text.fill", "text.bubble.fill", "lightbulb.fill", "calendar", "checklist", "bookmark.fill", "tag.fill", "terminal.fill",
        "chevron.left.forwardslash.chevron.right", "pencil", "quote.bubble.fill", "flag.fill", "wand.and.stars", "cup.and.saucer.fill", "dumbbell.fill", "stethoscope",
    ]
}

/// A rounded-square tile with a white symbol on the folder color, used in the sidebar and the folder editor.
struct FolderTile: View {
    var appearance: FolderAppearance
    var size: CGFloat = 20

    var body: some View {
        let base = appearance.color?.color ?? Color.accentColor
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [base.mix(with: .white, by: 0.12), base], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: appearance.icon ?? FolderIcons.defaultIcon)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: size * 0.02, y: size * 0.02)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Sidebar icon: the styled tile when a folder has a style, otherwise a plain folder symbol.
struct FolderIcon: View {
    var appearance: FolderAppearance

    var body: some View {
        if appearance.isDefault {
            Image(systemName: "folder")
        } else {
            FolderTile(appearance: appearance, size: 18)
        }
    }
}
