import AppKit
import SwiftUI

/// Design tokens shared by the app's windows and panels: an 8 pt spacing grid, a short
/// type scale where hierarchy comes from weight, neutral system colours (so light and dark
/// mode come for free) and one accent. Red is reserved for recording. Buttons and the
/// segmented control follow the litterthanlit/components design system, with an iPod
/// classic silver for the primary button.
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
        static let audioTrack = Color(nsColor: .systemGreen)
        static let playhead = Color(nsColor: .systemYellow)

        // Primary button: a silver iPod in light mode, a black one in dark.
        static let silverTop = Color(light: NSColor(hex: 0xEEEFF2), dark: NSColor(hex: 0x55575C))
        static let silverBottom = Color(light: NSColor(hex: 0xCDD0D4), dark: NSColor(hex: 0x37393D))
        static let silverRing = Color(light: NSColor(white: 0, alpha: 0.17), dark: NSColor(white: 0, alpha: 0.6))
        static let silverHighlight = Color(light: NSColor(white: 1, alpha: 0.95), dark: NSColor(white: 1, alpha: 0.15))
        static let silverHover = Color(light: NSColor(white: 1, alpha: 0.4), dark: NSColor(white: 1, alpha: 0.07))
        static let silverLabel = Color(light: NSColor(hex: 0x1D1D1F), dark: NSColor(hex: 0xF5F5F7))

        // Recording buttons: the components repo's danger red.
        static let danger = Color(light: NSColor(hex: 0xD93036), dark: NSColor(hex: 0xFF6166))
        static let onDanger = Color(light: .white, dark: NSColor(hex: 0x0A0A0A))

        // Secondary buttons and the segmented control: raised surfaces with a hairline ring.
        static let buttonSurface = Color(light: .white, dark: NSColor(hex: 0x303032))
        static let buttonShadow = Color(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 0, alpha: 0.4))
        static let hairline = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
        static let hairlineStrong = Color(light: NSColor(white: 0, alpha: 0.17), dark: NSColor(white: 1, alpha: 0.17))
        static let track = Color(light: NSColor(white: 0, alpha: 0.055), dark: NSColor(white: 0, alpha: 0.28))
        static let thumb = Color(light: .white, dark: NSColor(hex: 0x4A4A4D))
    }

    /// Button heights: small for dense editor chrome, regular for the main actions of a
    /// sheet, a panel or an empty state.
    enum ButtonSize {
        case small
        case regular

        var height: CGFloat { self == .small ? 28 : 36 }
        var cornerRadius: CGFloat { self == .small ? Radius.small : Radius.medium }
        var horizontalPadding: CGFloat { self == .small ? 10 : 14 }
        var font: Font { self == .small ? Typeface.footnote.weight(.medium) : Typeface.body.weight(.medium) }
    }

    /// Interaction timing: hover fades in over 210 ms and out over 150 ms on an ease-out
    /// curve that answers at once and settles slowly; a press scales to 0.97.
    enum Motion {
        static let pressScale: CGFloat = 0.97
        static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)

        static func hover(entering: Bool) -> Animation {
            .timingCurve(0.23, 1, 0.32, 1, duration: entering ? 0.21 : 0.15)
        }

        /// A segmented control's thumb follows a stiff spring; with Reduce Motion it jumps.
        static func indicator(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .interpolatingSpring(stiffness: 520, damping: 40)
        }
    }

    /// Springs that settle quickly; with Reduce Motion they become a short fade.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.86)
    }
}

extension Color {
    /// A colour that follows the appearance: `light` in Aqua, `dark` in Dark Aqua.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    /// An sRGB colour from a hex literal such as 0x6E56CF.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
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

/// Hover and press behaviour shared by the button styles: the hover state animates with
/// `DS.Motion`, a press scales the button down (colour only with Reduce Motion) and a
/// disabled button is drawn at half strength.
private struct ButtonFeedback: ViewModifier {
    let isPressed: Bool
    let scales: Bool
    @Binding var isHovering: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let pressScale: CGFloat = isPressed && scales && !reduceMotion ? DS.Motion.pressScale : 1
        return content
            .scaleEffect(pressScale)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(DS.Motion.press, value: isPressed)
            .onHover { hovering in
                withAnimation(DS.Motion.hover(entering: hovering)) {
                    isHovering = hovering
                }
            }
    }
}

private extension View {
    func buttonFeedback(isPressed: Bool, isHovering: Binding<Bool>, scales: Bool = true) -> some View {
        modifier(ButtonFeedback(isPressed: isPressed, scales: scales, isHovering: isHovering))
    }
}

/// The one filled button per view. The standard finish is iPod classic silver: a gradient
/// with a hairline ring and a lit top edge that turns over when pressed, like pushing the
/// click wheel's centre button. Recording actions are filled with the danger red instead.
struct PrimaryButtonStyle: ButtonStyle {
    enum Kind {
        case silver
        case recording
    }

    var kind: Kind
    var size: DS.ButtonSize

    init(_ kind: Kind = .silver, size: DS.ButtonSize = .small) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, kind: kind, size: size)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let size: DS.ButtonSize
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            let label: Color = kind == .silver ? DS.Palette.silverLabel : DS.Palette.onDanger
            return configuration.label
                .font(size.font)
                .foregroundStyle(label)
                .padding(.horizontal, size.horizontalPadding)
                .frame(minHeight: size.height)
                .background { fill(shape) }
                .contentShape(shape)
                .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering)
        }

        @ViewBuilder
        private func fill(_ shape: RoundedRectangle) -> some View {
            switch kind {
            case .silver:
                silverFill(shape)
            case .recording:
                recordingFill(shape)
            }
        }

        private func silverFill(_ shape: RoundedRectangle) -> some View {
            let isPressed = configuration.isPressed
            let resting = LinearGradient(
                colors: [DS.Palette.silverTop, DS.Palette.silverBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            let turnedOver = LinearGradient(
                colors: [DS.Palette.silverBottom, DS.Palette.silverTop],
                startPoint: .top,
                endPoint: .bottom
            )
            let highlight = LinearGradient(
                colors: [DS.Palette.silverHighlight, DS.Palette.silverHighlight.opacity(0)],
                startPoint: .top,
                endPoint: .center
            )
            return ZStack {
                shape
                    .fill(resting)
                    .shadow(color: DS.Palette.buttonShadow, radius: 1, y: 1)
                shape
                    .fill(turnedOver.shadow(.inner(color: .black.opacity(0.22), radius: 1.5, y: 1)))
                    .opacity(isPressed ? 1 : 0)
                shape
                    .fill(DS.Palette.silverHover)
                    .opacity(isHovering && !isPressed ? 1 : 0)
                shape
                    .inset(by: 1)
                    .strokeBorder(highlight, lineWidth: 1)
                    .opacity(isPressed ? 0 : 1)
                shape
                    .strokeBorder(DS.Palette.silverRing, lineWidth: 1)
            }
        }

        private func recordingFill(_ shape: RoundedRectangle) -> some View {
            let restingOpacity: Double = isHovering ? 0.85 : 1
            return shape
                .fill(DS.Palette.danger)
                .opacity(configuration.isPressed ? 1 : restingOpacity)
                .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
        }
    }
}

/// Quiet button: a raised surface with a hairline ring that darkens on hover.
struct SecondaryButtonStyle: ButtonStyle {
    var size: DS.ButtonSize = .small

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, size: size)
    }

    private struct SecondaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: DS.ButtonSize
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            let ring: Color = isHovering ? DS.Palette.hairlineStrong : DS.Palette.hairline
            return configuration.label
                .font(size.font)
                .padding(.horizontal, size.horizontalPadding)
                .frame(minHeight: size.height)
                .background {
                    ZStack {
                        shape
                            .fill(DS.Palette.buttonSurface)
                            .shadow(color: DS.Palette.buttonShadow, radius: 1, y: 1)
                        shape
                            .fill(DS.Palette.hover)
                            .opacity(configuration.isPressed ? 1 : 0)
                        shape
                            .strokeBorder(ring, lineWidth: 1)
                    }
                }
                .contentShape(shape)
                .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering)
        }
    }
}

/// Icon-only ghost button: a muted glyph that turns full strength over a hover fill.
/// Always give it an accessibility label.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var isHovering = false

        var body: some View {
            let radius: CGFloat = size >= 32 ? DS.Radius.medium : DS.Radius.small
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let glyph: Color = isHovering ? Color.primary : DS.Palette.secondaryText
            return configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(glyph)
                .frame(width: size, height: size)
                .background(shape.fill(fill))
                .contentShape(shape)
                .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering)
        }

        private var fill: Color {
            if configuration.isPressed { return DS.Palette.pressed }
            return isHovering ? DS.Palette.hover : .clear
        }
    }
}

/// A row that highlights on hover, for list-like menus in the panel. Rows keep their own
/// label colours and don't scale when pressed.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRowBody(configuration: configuration)
    }

    private struct HoverRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(fill)
                )
                .contentShape(Rectangle())
                .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering, scales: false)
        }

        private var fill: Color {
            if configuration.isPressed { return DS.Palette.pressed }
            return isHovering ? DS.Palette.hover : .clear
        }
    }
}

/// A tile-shaped ghost button: muted at rest, full strength over a hover fill. Used for
/// the icon-over-caption actions in Quick Access.
struct GhostTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostTileBody(configuration: configuration)
    }

    private struct GhostTileBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            let tint: Color = isHovering ? Color.primary : DS.Palette.secondaryText
            return configuration.label
                .foregroundStyle(tint)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(fill)
                )
                .contentShape(Rectangle())
                .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering)
        }

        private var fill: Color {
            if configuration.isPressed { return DS.Palette.pressed }
            return isHovering ? DS.Palette.hover : .clear
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
