import SwiftUI

/// Design tokens shared by the app's windows and panels: an 8 pt spacing grid, a short
/// type scale where hierarchy comes from weight, neutral system colours (so light and dark
/// mode come for free) and one accent. Red is reserved for recording.
enum DS {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }

    enum Typeface {
        static let caption = Font.system(size: 11)
        static let footnote = Font.system(size: 12)
        static let body = Font.system(size: 13)
        static let headline = Font.system(size: 13, weight: .semibold)
        static let title = Font.system(size: 15, weight: .semibold)
        static let largeTitle = Font.system(size: 20, weight: .semibold)
        static let display = Font.system(size: 28, weight: .bold)
        static let timecode = Font.system(size: 12, weight: .medium).monospacedDigit()
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
    }

    enum Palette {
        static let accent = Color.accentColor
        static let recording = Color(nsColor: .systemRed)
        static let success = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let raisedSurface = Color.primary.opacity(0.05)
        static let hover = Color.primary.opacity(0.07)
        static let pressed = Color.primary.opacity(0.12)
        static let separator = Color(nsColor: .separatorColor)
        static let canvas = Color(nsColor: .underPageBackgroundColor)
        static let secondaryText = Color.secondary
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)

        // Timeline tracks. Always shown with an icon and a label, never colour alone.
        static let clipTrack = Color(nsColor: .systemGray)
        static let zoomTrack = Color.accentColor
        static let manualZoomTrack = Color(nsColor: .systemOrange)
        static let textTrack = Color(nsColor: .systemTeal)
        static let blurTrack = Color(nsColor: .systemPink)
        static let cameraTrack = Color(nsColor: .systemIndigo)
        static let audioTrack = Color(nsColor: .systemGreen)
        static let playhead = Color(nsColor: .systemYellow)
    }

    /// Springs that settle quickly; with Reduce Motion they become a short fade.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.86)
    }
}

/// Small-caps section label used in the panel and inspector.
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(DS.Typeface.sectionHeader)
            .tracking(0.6)
            .foregroundStyle(DS.Palette.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The one filled button per view: accent background, white label.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = DS.Palette.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typeface.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(tint.opacity(isEnabled ? 1 : 0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }
}

/// Quiet button: tinted neutral fill that darkens on hover and press.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }

    private struct SecondaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(DS.Typeface.body)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 6)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(configuration.isPressed ? DS.Palette.pressed : (isHovering ? DS.Palette.hover : DS.Palette.raisedSurface))
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                .onHover { isHovering = $0 }
        }
    }
}

/// Icon-only button with a circular hover highlight. Always give it an accessibility label.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(configuration.isPressed ? DS.Palette.pressed : (isHovering ? DS.Palette.hover : .clear))
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}

/// A row that highlights on hover, for list-like menus in the panel.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRowBody(configuration: configuration)
    }

    private struct HoverRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(configuration.isPressed ? DS.Palette.pressed : (isHovering ? DS.Palette.hover : .clear))
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}

/// A shortcut shown as a small keycap-style label, e.g. ⇧⌘R.
struct ShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospaced())
            .foregroundStyle(DS.Palette.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(DS.Palette.separator)
            )
            .accessibilityLabel("Shortcut \(text)")
    }
}
