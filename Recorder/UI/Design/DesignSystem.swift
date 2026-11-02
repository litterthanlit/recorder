import AppKit
import SwiftUI

/// Design tokens shared by the app's windows and panels, after the litt design system
/// (litt.design, litterthanlit/components): flat and quiet. Text is ink or muted, raised
/// things get a hairline ring and a soft low shadow rather than a box, recessed areas a
/// panel tint. One accent, lime, is a signal: a fill with ink on it, never text on a light
/// ground (as text or a stroke it is `accent`, a deep green in light mode). Red is
/// reserved for recording and destructive actions. An 8 pt spacing grid and a short type
/// scale where hierarchy comes from size and one weight step (regular to medium).
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
        /// Small buttons, chips, kbd.
        static let small: CGFloat = 6
        /// Buttons, inputs, icon buttons.
        static let medium: CGFloat = 8
        /// Previews, cards, toasts.
        static let large: CGFloat = 12
    }

    /// litt's type has one weight step: regular for everything, medium for titles and
    /// labels. Nothing is bold.
    enum Typeface {
        static let caption = Font.system(size: 11)
        static let footnote = Font.system(size: 12)
        static let body = Font.system(size: 13)
        static let headline = Font.system(size: 13, weight: .medium)
        static let title = Font.system(size: 15, weight: .medium)
        static let largeTitle = Font.system(size: 20, weight: .medium)
        static let display = Font.system(size: 28, weight: .medium)
        static let timecode = Font.system(size: 12, weight: .medium).monospacedDigit()
        static let sectionHeader = Font.system(size: 12)
    }

    enum Palette {
        /// Primary text, and the fill of primary buttons.
        static let ink = Color(light: NSColor(hex: 0x0A0A0A), dark: NSColor(hex: 0xEDEDED))
        /// Secondary text, meta and icons (4.5:1 or more on canvas, panel and surface).
        static let muted = Color(light: NSColor(hex: 0x707070), dark: NSColor(hex: 0x8F8F8F))
        /// Page ground, and text on ink and danger fills.
        static let canvasInk = Color(light: NSColor(hex: 0xFAFAFA), dark: NSColor(hex: 0x0A0A0A))
        /// Raised objects: cards, menus, secondary buttons, the segmented control's thumb.
        static let raised = Color(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x171717))
        /// Recessed areas: tracks, hover fills, stages.
        static let panel = Color(light: NSColor(hex: 0xF5F5F5), dark: NSColor(hex: 0x111111))

        /// The accent as text or a stroke: deep green in light mode, lime in dark (litt's
        /// accent-strong; 4.6:1 on panel in light).
        static let accent = Color(light: NSColor(hex: 0x4D7C0F), dark: NSColor(hex: 0xC2FF4D))
        /// The accent as a fill: lime in both themes, always with `accentInk` on it.
        static let accentFill = Color(nsColor: NSColor(hex: 0xC2FF4D))
        /// Text and icons on `accentFill` (16.7:1).
        static let accentInk = Color(nsColor: NSColor(hex: 0x0A0A0A))
        /// Recording, and destructive fills (litt's danger).
        static let recording = Color(light: NSColor(hex: 0xD93036), dark: NSColor(hex: 0xFF6166))
        static let success = accent
        static let warning = Color(nsColor: .systemOrange)
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let raisedSurface = Color.primary.opacity(0.05)
        static let hover = Color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.06))
        static let pressed = Color(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.1))
        static let separator = Color(nsColor: .separatorColor)
        static let canvas = Color(nsColor: .underPageBackgroundColor)
        static let secondaryText = muted
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)

        // Timeline tracks. Always shown with an icon and a label, never colour alone.
        static let clipTrack = Color(nsColor: .systemGray)
        static let zoomTrack = accent
        static let manualZoomTrack = Color(nsColor: .systemOrange)
        static let textTrack = Color(nsColor: .systemTeal)
        static let blurTrack = Color(nsColor: .systemPink)
        static let cameraTrack = Color(nsColor: .systemIndigo)
        static let audioTrack = Color(nsColor: .systemBlue)
        static let playhead = Color(nsColor: .systemYellow)

        /// Hairlines, and the 1 px ring inside every raised object's shadow.
        static let hairline = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
        /// A hairline under the pointer.
        static let hairlineStrong = Color(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.15))
        /// The soft low shadow under a ring (litt's shadow-sm).
        static let buttonShadow = Color(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 0, alpha: 0.4))
        // The segmented control: a panel-tinted track with a raised thumb.
        static let track = panel
        static let thumb = raised
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

/// A section label in the panel and inspector: sentence case in muted, as litt labels
/// sections (no capitals, no tracking).
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(DS.Typeface.sectionHeader)
            .foregroundStyle(DS.Palette.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Hover and press behaviour shared by the button styles: the hover state animates with
/// `DS.Motion`, a press scales the button to 0.97 (colour only with Reduce Motion) and a
/// disabled button is drawn at half strength.
private struct ButtonFeedback: ViewModifier {
    let isPressed: Bool
    @Binding var isHovering: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let pressScale: CGFloat = isPressed && !reduceMotion ? DS.Motion.pressScale : 1
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
    func buttonFeedback(isPressed: Bool, isHovering: Binding<Bool>) -> some View {
        modifier(ButtonFeedback(isPressed: isPressed, isHovering: isHovering))
    }
}

/// A solid flat button: ink (or recording red) with the canvas colour on it. Hovering
/// lifts it a little.
private struct SolidButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let label: Color
    let size: DS.ButtonSize
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
        return configuration.label
            .font(size.font)
            .foregroundStyle(label)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .background(shape.fill(fill).opacity(isHovering && !configuration.isPressed ? 0.88 : 1))
            .contentShape(shape)
            .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering)
    }
}

/// The one primary action per view: solid ink. Recording actions use the red one.
struct PrimaryButtonStyle: ButtonStyle {
    enum Kind {
        case standard
        case recording
    }

    var kind: Kind
    var size: DS.ButtonSize

    init(_ kind: Kind = .standard, size: DS.ButtonSize = .small) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = kind == .standard ? DS.Palette.ink : DS.Palette.recording
        return SolidButtonBody(configuration: configuration, fill: fill, label: DS.Palette.canvasInk, size: size)
    }
}

/// Quiet button: a raised surface with a hairline ring and a soft shadow, ink lettering.
/// The ring darkens under the pointer.
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
                .foregroundStyle(DS.Palette.ink)
                .padding(.horizontal, size.horizontalPadding)
                .frame(minHeight: size.height)
                .background {
                    shape
                        .fill(configuration.isPressed ? DS.Palette.panel : DS.Palette.raised)
                        .shadow(color: DS.Palette.buttonShadow, radius: 1, y: 1)
                        .overlay(shape.strokeBorder(ring, lineWidth: 1))
                }
                .contentShape(shape)
                .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering)
        }
    }
}

/// Icon-only ghost button: a muted glyph that turns ink over a panel-tinted hover fill.
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
            let shape = RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            let glyph: Color = isHovering ? DS.Palette.ink : DS.Palette.secondaryText
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
                .buttonFeedback(isPressed: configuration.isPressed, isHovering: $isHovering)
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
            let tint: Color = isHovering ? DS.Palette.ink : DS.Palette.secondaryText
            return configuration.label
                .foregroundStyle(tint)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
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
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(DS.Palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DS.Palette.hairline))
            )
            .accessibilityLabel("Shortcut \(text)")
    }
}
