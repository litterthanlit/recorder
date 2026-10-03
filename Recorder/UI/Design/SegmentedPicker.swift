import SwiftUI

/// A pill track whose raised thumb springs between the options, after the components
/// repo's SegmentedControl. VoiceOver reads it as a native segmented control; with Full
/// Keyboard Access each option is reachable and the arrow keys move the selection.
/// `fillsWidth` makes the options share the available width equally, for narrow columns
/// like the inspector (the native control keeps a minimum width of its own).
struct SegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let fillsWidth: Bool
    let label: (Value) -> String
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        fillsWidth: Bool = false,
        label: @escaping (Value) -> String
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.fillsWidth = fillsWidth
        self.label = label
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                PickerSegment(
                    title: label(option),
                    isSelected: option == selection,
                    fillsWidth: fillsWidth,
                    namespace: namespace
                ) {
                    selection = option
                }
            }
        }
        .padding(3)
        .background(track)
        .animation(DS.Motion.indicator(reduceMotion: reduceMotion), value: selection)
        .onMoveCommand(perform: move)
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var track: some View {
        Capsule(style: .continuous)
            .fill(DS.Palette.track)
            .overlay(Capsule(style: .continuous).strokeBorder(DS.Palette.hairline, lineWidth: 1))
    }

    private func move(_ direction: MoveCommandDirection) {
        let step: Int
        switch direction {
        case .left:
            step = -1
        case .right:
            step = 1
        default:
            return
        }
        guard let index = options.firstIndex(of: selection), !options.isEmpty else { return }
        selection = options[(index + step + options.count) % options.count]
    }
}

private struct PickerSegment: View {
    let title: String
    let isSelected: Bool
    let fillsWidth: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let tint: Color = isSelected || isHovering ? Color.primary : DS.Palette.secondaryText
        let maxWidth: CGFloat? = fillsWidth ? .infinity : nil
        let padding: CGFloat = fillsWidth ? DS.Spacing.xxs : DS.Spacing.sm
        return Button(action: action) {
            Text(title)
                .font(DS.Typeface.footnote.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(tint)
                .padding(.horizontal, padding)
                .frame(maxWidth: maxWidth, minHeight: 24)
                .background { thumb }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DS.Motion.hover(entering: hovering)) {
                isHovering = hovering
            }
        }
    }

    /// The selected option's raised thumb; it slides to the new choice.
    @ViewBuilder
    private var thumb: some View {
        if isSelected {
            Capsule(style: .continuous)
                .fill(DS.Palette.thumb)
                .shadow(color: DS.Palette.buttonShadow, radius: 1, y: 1)
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Palette.hairline, lineWidth: 1))
                .matchedGeometryEffect(id: "thumb", in: namespace)
        }
    }
}
