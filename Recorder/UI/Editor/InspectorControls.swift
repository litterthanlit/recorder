import AppKit
import SwiftUI

/// A titled group of settings in the inspector.
struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionHeader(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A slider with its name and current value above it.
struct InspectorSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(title)
                    .font(DS.Typeface.body)
                Spacer(minLength: DS.Spacing.xs)
                Text(format(value))
                    .font(DS.Typeface.timecode)
                    .foregroundStyle(DS.Palette.secondaryText)
            }
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
        }
    }
}

/// A slider whose whole drag is one undo step.
struct EditorSlider: View {
    let editor: ProjectEditor
    let title: String
    let actionName: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        InspectorSlider(title: title, value: value, range: range, format: format) { isEditing in
            if isEditing {
                editor.beginInteractiveEdit(actionName)
            } else {
                editor.endInteractiveEdit()
            }
        }
    }
}

/// A setting that's on or off: its name (and a short explanation) on the left, a
/// switch on the right.
struct InspectorToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typeface.body)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Typeface.caption)
                        .foregroundStyle(DS.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.xs)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityHint(subtitle ?? "")
        }
    }
}

/// A short explanation under a setting.
struct InspectorHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(DS.Typeface.caption)
            .foregroundStyle(DS.Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A label above a control, for pickers.
struct InspectorLabeled<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(title)
                .font(DS.Typeface.body)
            content
        }
    }
}

/// Equal-width choices in a track that always fits the inspector column. (The native
/// segmented control keeps a minimum width of its own; five segments pushed the whole
/// inspector past both of its edges.)
struct InspectorSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                InspectorSegment(title: label(option), isSelected: option == selection, namespace: namespace) {
                    selection = option
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(DS.Palette.raisedSurface)
        )
        .animation(DS.animation(reduceMotion: reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct InspectorSegment: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let tint: Color = isSelected ? DS.Palette.accent : DS.Palette.secondaryText
        let weight: Font.Weight = isSelected ? .semibold : .regular
        return Button(action: action) {
            Text(title)
                .font(DS.Typeface.footnote.weight(weight))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(tint)
                .padding(.horizontal, DS.Spacing.xxs)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background { highlight }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The selected segment's fill slides to the new choice.
    @ViewBuilder
    private var highlight: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
        if isSelected {
            shape
                .fill(DS.Palette.accent.opacity(0.16))
                .matchedGeometryEffect(id: "selection", in: namespace)
        } else if isHovering {
            shape.fill(DS.Palette.hover)
        }
    }
}

/// A destructive action at the bottom of a selection's settings.
struct InspectorDeleteButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .foregroundStyle(DS.Palette.recording)
    }
}

// MARK: - Colours

extension RGBAColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
    }
}

extension BackgroundStyle {
    /// Where a CSS-style angle starts and ends in a SwiftUI shape (y down).
    static func unitPoints(angle: Double) -> (start: UnitPoint, end: UnitPoint) {
        let radians = angle * .pi / 180
        let dx = sin(radians) / 2
        let dy = -cos(radians) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// A small picture of a background, for pickers and look chips.
struct BackgroundSwatch: View {
    let style: BackgroundStyle

    var body: some View {
        ZStack {
            switch style.kind {
            case .wallpaper:
                wallpaper
            case .gradient:
                gradient(style.gradientStart, style.gradientEnd, angle: style.gradientAngle)
            case .solid:
                style.solidColor.color
            case .image:
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "photo")
                        .foregroundStyle(DS.Palette.secondaryText)
                }
            case .none:
                Color.black
            }
        }
    }

    private var wallpaper: some View {
        let colors = style.wallpaper.colors
        return ZStack {
            gradient(colors.start, colors.end, angle: 135)
            RadialGradient(
                colors: [colors.glow.color, colors.glow.color.opacity(0)],
                center: UnitPoint(x: 0.18, y: 0.1),
                startRadius: 0,
                endRadius: 60
            )
        }
    }

    private func gradient(_ start: RGBAColor, _ end: RGBAColor, angle: Double) -> LinearGradient {
        let points = BackgroundStyle.unitPoints(angle: angle)
        return LinearGradient(colors: [start.color, end.color], startPoint: points.start, endPoint: points.end)
    }
}

// MARK: - Bindings

extension ProjectEditor {
    /// A colour setting as a SwiftUI colour, for `ColorPicker`. Changes while the colour
    /// panel is being dragged are one undo step.
    func colorBinding(_ keyPath: WritableKeyPath<ProjectEditSettings, RGBAColor>, actionName: String) -> Binding<Color> {
        let binding = settingBinding(keyPath, actionName: actionName, coalesce: true)
        return Binding(
            get: { binding.wrappedValue.color },
            set: { binding.wrappedValue = RGBAColor($0) }
        )
    }

    /// A `CGFloat` setting as a `Double`, for sliders.
    func doubleBinding(_ keyPath: WritableKeyPath<ProjectEditSettings, CGFloat>, actionName: String) -> Binding<Double> {
        let binding = settingBinding(keyPath, actionName: actionName, continuous: true)
        return Binding(
            get: { Double(binding.wrappedValue) },
            set: { binding.wrappedValue = CGFloat($0) }
        )
    }
}
