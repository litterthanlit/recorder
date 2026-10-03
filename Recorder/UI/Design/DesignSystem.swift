import AppKit
import SwiftUI

/// Design tokens shared by the app's windows and panels: an 8 pt spacing grid, a short
/// type scale where hierarchy comes from weight, neutral system colours (so light and dark
/// mode come for free) and one blue accent. Red is reserved for recording. Buttons, the
/// accent and the segmented control follow the litterthanlit/components design system:
/// buttons are keys, and the primary key wears the iPod classic's silver.
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
        /// Keys: buttons that read as physical.
        static let key: CGFloat = 2
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
        /// The accent for text, strokes and tints: blue, lifted in dark mode so it stays legible.
        static let accent = Color(light: NSColor(hex: 0x384ECB), dark: NSColor(hex: 0x8A9AF2))
        /// The accent as a solid fill under white content (the asset catalog's AccentColor).
        static let accentFill = Color.accentColor
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
        static let zoomTrack = accent
        static let manualZoomTrack = Color(nsColor: .systemOrange)
        static let textTrack = Color(nsColor: .systemTeal)
        static let blurTrack = Color(nsColor: .systemPink)
        static let audioTrack = Color(nsColor: .systemGreen)
        static let playhead = Color(nsColor: .systemYellow)

        // The segmented control: a recessed track with a raised thumb.
        static let buttonShadow = Color(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 0, alpha: 0.4))
        static let hairline = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
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
    /// curve that answers at once and settles slowly. A key sinks 2 pt onto its base in
    /// 75 ms and rises in 150 ms; a ghost button scales to 0.97 instead.
    enum Motion {
        static let pressScale: CGFloat = 0.97
        static let keyTravel: CGFloat = 2

        static func press(_ isPressed: Bool) -> Animation {
            .timingCurve(0.23, 1, 0.32, 1, duration: isPressed ? 0.075 : 0.15)
        }

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
    /// An sRGB colour from a hex literal such as 0x384ECB.
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
/// `DS.Motion`, a press scales a ghost button down (keys sink instead; colour only with
/// Reduce Motion) and a disabled button is drawn at half strength.
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
            .animation(DS.Motion.press(isPressed), value: isPressed)
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

/// The colours of a key: the face, the lettering and the cut that sets it into the face,
/// the ring and the base the face sinks onto, the lit top edge and the shadows. Values
/// follow the `--key-*` tokens in litterthanlit/components.
struct KeyFinish {
    let face: [Color]
    let label: Color
    let engraveShadow: Color
    let engraveLight: Color
    let ring: Color
    let base: Color
    let highlight: Color
    let drop: Color
    let pressedShade: Color

    /// White keys (near-black in dark mode), for secondary actions.
    static let plain = KeyFinish(
        face: [tone(0xFFFFFF, 0x2A2A2A), tone(0xF1F1F1, 0x1C1C1C)],
        label: tone(0x5A5A5A, 0xBDBDBD),
        engraveShadow: black(0.28, 0.9),
        engraveLight: white(0.95, 0.1),
        ring: black(0.12, 0.8),
        base: black(0.12, 1),
        highlight: white(0.9, 0.09),
        drop: black(0.14, 0.6),
        pressedShade: black(0.12, 0.7)
    )

    /// The primary key, in the iPod classic's finishes: the silver plate in light mode,
    /// graphite in dark.
    static let silver = KeyFinish(
        face: [tone(0xE2E3E6, 0x5A5C61), tone(0xD1D3D7, 0x4A4C50), tone(0xC3C6CA, 0x3C3E42)],
        label: tone(0x3B3F44, 0xF2F2F4),
        engraveShadow: black(0.22, 0.8),
        engraveLight: white(0.6, 0.1),
        ring: black(0.22, 0.85),
        base: tone(0x8E959C, 0x000000),
        highlight: white(0.75, 0.16),
        drop: black(0.18, 0.6),
        pressedShade: black(0.2, 0.6)
    )

    /// Record and Stop: the danger red as a key.
    static let recording = KeyFinish(
        face: [tone(0xE5484D, 0xFF6F73), tone(0xC62A30, 0xE5484D)],
        label: Color(light: NSColor(white: 1, alpha: 0.94), dark: NSColor(hex: 0x0A0A0A)),
        engraveShadow: black(0.3, 0.2),
        engraveLight: white(0.12, 0.35),
        ring: Color(light: NSColor(hex: 0x8F1A1E), dark: NSColor(white: 0, alpha: 0.8)),
        base: tone(0x8F1A1E, 0x000000),
        highlight: white(0.25, 0.3),
        drop: black(0.25, 0.6),
        pressedShade: black(0.35, 0.35)
    )

    private static func tone(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    private static func black(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(light: NSColor(white: 0, alpha: light), dark: NSColor(white: 0, alpha: dark))
    }

    private static func white(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(light: NSColor(white: 1, alpha: light), dark: NSColor(white: 1, alpha: dark))
    }
}

/// A key: a face on a 2 pt base that it sinks onto while pressed, with a lit top edge
/// and lettering cut into the face. Hovering brightens it a little. With Reduce Motion
/// the face stays put and only its shading changes.
private struct KeyBody: View {
    let configuration: ButtonStyleConfiguration
    let finish: KeyFinish
    let size: DS.ButtonSize
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.key, style: .continuous)
        let sink: CGFloat = configuration.isPressed && !reduceMotion ? DS.Motion.keyTravel : 0
        return configuration.label
            .font(size.font)
            .foregroundStyle(finish.label)
            .shadow(color: finish.engraveShadow, radius: 0, y: -0.5)
            .shadow(color: finish.engraveLight, radius: 0, y: 1)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .background { face(shape) }
            .offset(y: sink)
            .background { base(shape) }
            .contentShape(shape)
            .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering, scales: false)
    }

    private func face(_ shape: RoundedRectangle) -> some View {
        let isPressed = configuration.isPressed
        let gradient = LinearGradient(colors: finish.face, startPoint: .top, endPoint: .bottom)
        let edge = LinearGradient(
            colors: [finish.highlight, finish.highlight.opacity(0)],
            startPoint: .top,
            endPoint: .center
        )
        let lift: Double = isHovering && !isPressed ? 0.04 : 0
        return ZStack {
            shape
                .fill(gradient)
            shape
                .fill(gradient.shadow(.inner(color: finish.pressedShade, radius: 1.5, y: 1)))
                .opacity(isPressed ? 1 : 0)
            shape
                .inset(by: 1)
                .strokeBorder(edge, lineWidth: 1)
                .opacity(isPressed ? 0 : 1)
            shape
                .strokeBorder(finish.ring, lineWidth: 1)
        }
        .brightness(lift)
    }

    /// The base shows as a 2 pt ledge under the face and carries the drop shadow, which
    /// tightens when the face comes down onto it.
    private func base(_ shape: RoundedRectangle) -> some View {
        let isPressed = configuration.isPressed
        let drop: Color = isPressed ? .clear : finish.drop
        return shape
            .fill(finish.base)
            .offset(y: DS.Motion.keyTravel)
            .shadow(color: drop, radius: 3, y: 2)
    }
}

/// The one primary key per view, in iPod classic silver. Recording actions use the red key.
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
        let finish: KeyFinish = kind == .silver ? .silver : .recording
        return KeyBody(configuration: configuration, finish: finish, size: size)
    }
}

/// Quiet button: a white key (near-black in dark mode) with grey lettering.
struct SecondaryButtonStyle: ButtonStyle {
    var size: DS.ButtonSize = .small

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, finish: .plain, size: size)
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
            let shape = RoundedRectangle(cornerRadius: DS.Radius.key, style: .continuous)
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
                    RoundedRectangle(cornerRadius: DS.Radius.key, style: .continuous)
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
