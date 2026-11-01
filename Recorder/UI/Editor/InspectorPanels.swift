import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Background

struct BackgroundInspector: View {
    @ObservedObject var editor: ProjectEditor

    private var style: ExportStyle { editor.editSettings.exportStyle }
    private var background: BackgroundStyle { style.background }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            LooksSection(editor: editor)
            backgroundSection
            frameSection
            canvasSection
            watermarkSection
        }
    }

    private var backgroundSection: some View {
        InspectorSection("Background") {
            BackgroundKindPicker(selection: editor.settingBinding(\.exportStyle.background.kind, actionName: "Background"))
            switch background.kind {
            case .wallpaper:
                WallpaperGrid(selection: editor.settingBinding(\.exportStyle.background.wallpaper, actionName: "Wallpaper"))
            case .gradient:
                gradientControls
            case .solid:
                solidControls
            case .image:
                imageControls
            case .none:
                InspectorHint("The recording fills the frame edge to edge, with no padding, corners or shadow.")
            }
        }
    }

    private var gradientControls: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.md) {
                ColorPicker(
                    "From",
                    selection: editor.colorBinding(\.exportStyle.background.gradientStart, actionName: "Gradient Color"),
                    supportsOpacity: false
                )
                ColorPicker(
                    "To",
                    selection: editor.colorBinding(\.exportStyle.background.gradientEnd, actionName: "Gradient Color"),
                    supportsOpacity: false
                )
            }
            .font(DS.Typeface.body)
            EditorSlider(
                editor: editor,
                title: "Angle",
                actionName: "Gradient Angle",
                value: editor.settingBinding(\.exportStyle.background.gradientAngle, actionName: "Gradient Angle", continuous: true),
                range: 0...360
            ) { "\(Int($0.rounded()))°" }
        }
    }

    private static let quickColors: [RGBAColor] = [
        RGBAColor(hex: "FFFFFF"), RGBAColor(hex: "F4F4F5"), RGBAColor(hex: "D4D4D8"), RGBAColor(hex: "18181B"),
        RGBAColor(hex: "000000"), RGBAColor(hex: "6E56CF"), RGBAColor(hex: "0EA5E9"), RGBAColor(hex: "F97316")
    ]

    private var solidControls: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ColorPicker(
                "Color",
                selection: editor.colorBinding(\.exportStyle.background.solidColor, actionName: "Background Color"),
                supportsOpacity: false
            )
            .font(DS.Typeface.body)
            HStack(spacing: 6) {
                ForEach(Self.quickColors, id: \.self) { color in
                    ColorDot(color: color, isSelected: background.solidColor.hexString == color.hexString) {
                        editor.settingBinding(\.exportStyle.background.solidColor, actionName: "Background Color").wrappedValue = color
                    }
                }
            }
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Button {
                    chooseImage()
                } label: {
                    Label(editor.project.backgroundImageURL == nil ? "Choose Image…" : "Replace Image…", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(SecondaryButtonStyle())
                if editor.project.backgroundImageURL == nil {
                    Text("No image yet")
                        .font(DS.Typeface.caption)
                        .foregroundStyle(DS.Palette.secondaryText)
                }
            }
            EditorSlider(
                editor: editor,
                title: "Blur",
                actionName: "Background Blur",
                value: editor.settingBinding(\.exportStyle.background.imageBlur, actionName: "Background Blur", continuous: true),
                range: 0...1
            ) { "\(Int(($0 * 100).rounded()))%" }
            InspectorHint("The image is copied into the recording, so moving the original is fine.")
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Image"
        panel.message = "Choose a picture to put behind the recording."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.useBackgroundImage(at: url)
    }

    private var frameSection: some View {
        InspectorSection("Frame") {
            EditorSlider(
                editor: editor,
                title: "Padding",
                actionName: "Padding",
                value: editor.doubleBinding(\.exportStyle.paddingRatio, actionName: "Padding"),
                range: 0...0.3
            ) { "\(Int(($0 * 100).rounded()))%" }
            EditorSlider(
                editor: editor,
                title: "Corners",
                actionName: "Corners",
                value: editor.doubleBinding(\.exportStyle.cornerRadius, actionName: "Corners"),
                range: 0...48
            ) { "\(Int($0.rounded())) pt" }
            InspectorToggle(title: "Shadow", isOn: editor.settingBinding(\.exportStyle.shadowEnabled, actionName: "Shadow"))
        }
        .disabled(!style.backgroundEnabled)
        .opacity(style.backgroundEnabled ? 1 : 0.45)
    }

    /// The recording's width over height once cropped, for the Auto shape.
    private var sourceAspect: CGFloat {
        let size = editor.contentSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16.0 / 9.0
    }

    private var canvasSection: some View {
        InspectorSection("Canvas") {
            InspectorLabeled("Shape") {
                AspectPicker(
                    selection: editor.settingBinding(\.canvas.aspect, actionName: "Change Shape"),
                    sourceAspect: sourceAspect
                )
                InspectorHint(editor.editSettings.canvas.aspect.useCase)
            }
            InspectorLabeled("Size") {
                InspectorSegmentedPicker(
                    "Size",
                    selection: editor.settingBinding(\.canvas.resolution, actionName: "Change Resolution"),
                    options: OutputResolution.allCases
                ) { $0.label }
                // String(_:) keeps the digits ungrouped: "1920", not "1,920".
                Text("\(String(Int(editor.exportOutputSize.width))) × \(String(Int(editor.exportOutputSize.height))) pixels")
                    .font(DS.Typeface.caption.monospacedDigit())
                    .foregroundStyle(DS.Palette.secondaryText)
            }
            CropControls(editor: editor)
        }
    }

    private var watermarkSection: some View {
        InspectorSection("Watermark") {
            InspectorToggle(title: "Show watermark", isOn: editor.settingBinding(\.exportStyle.watermarkEnabled, actionName: "Watermark"))
            if style.watermarkEnabled {
                TextField(
                    "yoursite.com",
                    text: editor.settingBinding(\.exportStyle.watermarkText, actionName: "Watermark Text", coalesce: true)
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Watermark text")
            }
        }
    }
}

private struct BackgroundKindPicker: View {
    @Binding var selection: BackgroundKind

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            ForEach(BackgroundKind.allCases) { kind in
                KindTile(kind: kind, isSelected: selection == kind) {
                    selection = kind
                }
            }
        }
    }

    private struct KindTile: View {
        let kind: BackgroundKind
        let isSelected: Bool
        let action: () -> Void

        private var icon: String {
            switch kind {
            case .wallpaper: return "sparkles"
            case .gradient: return "circle.lefthalf.filled"
            case .solid: return "square.fill"
            case .image: return "photo"
            case .none: return "rectangle.dashed"
            }
        }

        var body: some View {
            let tint: Color = isSelected ? DS.Palette.accent : DS.Palette.secondaryText
            let fill: Color = isSelected ? DS.Palette.accent.opacity(0.12) : DS.Palette.raisedSurface
            return Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                    Text(kind.label)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(fill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kind.label) background")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// The video's shapes as small frames in a row, so the choice reads at a glance.
private struct AspectPicker: View {
    @Binding var selection: OutputAspect
    /// Width over height of the recording, drawn (dashed) for Auto.
    let sourceAspect: CGFloat

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            ForEach(OutputAspect.allCases) { aspect in
                AspectTile(aspect: aspect, ratio: aspect.ratio ?? sourceAspect, isSelected: selection == aspect) {
                    selection = aspect
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shape")
    }

    private struct AspectTile: View {
        let aspect: OutputAspect
        let ratio: CGFloat
        let isSelected: Bool
        let action: () -> Void

        private static let glyphBox = CGSize(width: 20, height: 16)

        /// The largest frame of this shape that fits the glyph box.
        private var glyphSize: CGSize {
            let box = Self.glyphBox
            let clamped = min(max(ratio, 0.25), 4)
            return clamped >= box.width / box.height
                ? CGSize(width: box.width, height: box.width / clamped)
                : CGSize(width: box.height * clamped, height: box.height)
        }

        /// "16 by 9" rather than a time.
        private var spokenLabel: String {
            aspect == .auto ? "Auto" : aspect.label.replacingOccurrences(of: ":", with: " by ")
        }

        var body: some View {
            let tint: Color = isSelected ? DS.Palette.accent : DS.Palette.secondaryText
            let fill: Color = isSelected ? DS.Palette.accent.opacity(0.12) : DS.Palette.raisedSurface
            let dash: [CGFloat] = aspect == .auto ? [2.5, 2] : []
            let weight: Font.Weight = isSelected ? .semibold : .regular
            return Button(action: action) {
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: dash))
                        .frame(width: glyphSize.width, height: glyphSize.height)
                        .frame(width: Self.glyphBox.width, height: Self.glyphBox.height)
                    Text(aspect.label)
                        .font(.system(size: 10, weight: weight))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(fill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(aspect.label): \(aspect.useCase)")
            .accessibilityLabel(spokenLabel)
            .accessibilityHint(aspect.useCase)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

private struct WallpaperGrid: View {
    @Binding var selection: WallpaperPreset

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(WallpaperPreset.allCases) { preset in
                Button {
                    selection = preset
                } label: {
                    BackgroundSwatch(style: BackgroundStyle(kind: .wallpaper, wallpaper: preset))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.small + 2, style: .continuous)
                                .strokeBorder(selection == preset ? DS.Palette.accent : Color.primary.opacity(0.1), lineWidth: selection == preset ? 2 : 1)
                                .padding(-2)
                        )
                }
                .buttonStyle(.plain)
                .help(preset.label)
                .accessibilityLabel("\(preset.label) wallpaper")
                .accessibilityAddTraits(selection == preset ? .isSelected : [])
            }
        }
        .padding(2)
    }
}

private struct ColorDot: View {
    let color: RGBAColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .overlay(
                    Circle()
                        .strokeBorder(DS.Palette.accent, lineWidth: 2)
                        .padding(-3)
                        .opacity(isSelected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(color.hexString)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Cursor and keys

struct CursorInspector: View {
    @ObservedObject var editor: ProjectEditor

    private var hasCursor: Bool { !editor.project.cursorEvents.isEmpty }
    private var hasKeystrokes: Bool { !editor.project.inputs.keystrokes.isEmpty }
    private var keystrokes: KeystrokeOverlayStyle { editor.editSettings.exportStyle.keystrokes }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            cursorSection
            clicksSection
            keystrokeSection
        }
    }

    @ViewBuilder
    private var cursorSection: some View {
        InspectorSection("Cursor") {
            if hasCursor {
                InspectorToggle(title: "Show cursor", isOn: editor.settingBinding(\.exportStyle.showCursor, actionName: "Show Cursor"))
                Group {
                    EditorSlider(
                        editor: editor,
                        title: "Size",
                        actionName: "Cursor Size",
                        value: editor.settingBinding(\.exportStyle.cursorSize, actionName: "Cursor Size", continuous: true),
                        range: ExportStyle.cursorSizeRange
                    ) { String(format: "%.1f×", $0) }
                    InspectorToggle(
                        title: "Smooth movement",
                        subtitle: "Glides between positions instead of following every jitter.",
                        isOn: editor.settingBinding(\.exportStyle.cursorSmoothingEnabled, actionName: "Cursor Smoothing")
                    )
                    InspectorToggle(
                        title: "Hide when still",
                        subtitle: "Fades out after a moment without movement.",
                        isOn: editor.settingBinding(\.exportStyle.hideIdleCursor, actionName: "Hide Idle Cursor")
                    )
                    InspectorToggle(
                        title: "Bounce on click",
                        isOn: editor.settingBinding(\.exportStyle.cursorScaleOnClickEnabled, actionName: "Cursor Click Bounce")
                    )
                }
                .disabled(!editor.editSettings.exportStyle.showCursor)
            } else {
                InspectorHint("This recording shows the cursor as it was captured, so it can't be restyled.")
            }
        }
    }

    private var clicksSection: some View {
        InspectorSection("Clicks") {
            InspectorToggle(
                title: "Ripples",
                subtitle: "A ring spreads out from each click.",
                isOn: editor.settingBinding(\.exportStyle.clickRipplesEnabled, actionName: "Click Ripples")
            )
            InspectorToggle(
                title: "Spotlight",
                subtitle: "Dims everything but the area around the cursor.",
                isOn: editor.settingBinding(\.exportStyle.cursorSpotlightEnabled, actionName: "Cursor Spotlight")
            )
        }
    }

    private var keystrokeSection: some View {
        InspectorSection("Keystrokes") {
            InspectorLabeled("Show") {
                Picker("Show", selection: editor.settingBinding(\.exportStyle.keystrokes.filter, actionName: "Keystrokes")) {
                    ForEach(KeystrokeFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .labelsHidden()
            }
            if keystrokes.filter != .off {
                InspectorLabeled("Position") {
                    InspectorSegmentedPicker(
                        "Position",
                        selection: editor.settingBinding(\.exportStyle.keystrokes.placement, actionName: "Keystroke Position"),
                        options: KeystrokeOverlayStyle.Placement.allCases
                    ) { $0.label }
                }
                EditorSlider(
                    editor: editor,
                    title: "Size",
                    actionName: "Keystroke Size",
                    value: editor.settingBinding(\.exportStyle.keystrokes.scale, actionName: "Keystroke Size", continuous: true),
                    range: 0.5...2
                ) { "\(Int(($0 * 100).rounded()))%" }
            }
            if !hasKeystrokes {
                InspectorHint("No key presses were recorded with this take. Turn on “Show keystrokes” in Settings › Recording before your next one.")
            }
        }
    }
}

// MARK: - Camera

struct CameraInspector: View {
    @ObservedObject var editor: ProjectEditor

    private var camera: CameraOverlayStyle { editor.editSettings.camera }

    var body: some View {
        if editor.hasCameraTrack {
            controls
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Image(systemName: "video.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(DS.Palette.tertiaryText)
                Text("No camera in this recording")
                    .font(DS.Typeface.headline)
                InspectorHint("Turn on the camera in the menu bar panel before recording to add yourself in a bubble.")
            }
        }
    }

    private var sizeBinding: Binding<Double> {
        let binding = editor.settingBinding(\.camera.customSize, actionName: "Camera Size", continuous: true)
        return Binding(
            get: { Double(editor.editSettings.camera.diameterFraction) },
            set: { binding.wrappedValue = $0 }
        )
    }

    private var controls: some View {
        InspectorSection("Camera") {
            InspectorToggle(title: "Show camera", isOn: editor.settingBinding(\.camera.isVisible, actionName: "Show Camera"))
            Group {
                InspectorLabeled("Shape") {
                    InspectorSegmentedPicker(
                        "Shape",
                        selection: editor.settingBinding(\.camera.shape, actionName: "Camera Shape"),
                        options: CameraShape.allCases
                    ) { $0.label }
                }
                InspectorLabeled("Position") {
                    CornerPicker(selection: editor.settingBinding(\.camera.position, actionName: "Camera Position"))
                }
                EditorSlider(
                    editor: editor,
                    title: "Size",
                    actionName: "Camera Size",
                    value: sizeBinding,
                    range: CameraOverlayStyle.sizeRange
                ) { "\(Int(($0 * 100).rounded()))%" }
                InspectorToggle(title: "Border", isOn: editor.settingBinding(\.camera.borderEnabled, actionName: "Camera Border"))
            }
            .disabled(!camera.isVisible)
            .opacity(camera.isVisible ? 1 : 0.45)
        }
    }
}

/// Four corners of a small frame; the chosen one holds a dot.
private struct CornerPicker: View {
    @Binding var selection: CameraBubblePosition

    private let rows: [[CameraBubblePosition]] = [[.topLeft, .topRight], [.bottomLeft, .bottomRight]]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row]) { position in
                        cornerButton(position)
                    }
                }
            }
        }
        .frame(width: 120)
    }

    private func cornerButton(_ position: CameraBubblePosition) -> some View {
        let isSelected = selection == position
        let alignment: Alignment
        switch position {
        case .topLeft: alignment = .topLeading
        case .topRight: alignment = .topTrailing
        case .bottomLeft: alignment = .bottomLeading
        case .bottomRight: alignment = .bottomTrailing
        }
        return Button {
            selection = position
        } label: {
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? DS.Palette.accent.opacity(0.14) : DS.Palette.raisedSurface)
                Circle()
                    .fill(isSelected ? DS.Palette.accent : DS.Palette.tertiaryText)
                    .frame(width: 10, height: 10)
                    .padding(5)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(position.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Zoom

struct ZoomInspector: View {
    @ObservedObject var editor: ProjectEditor

    private var manualCount: Int { editor.keyframes.filter { $0.source == .manual }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            InspectorSection("Auto zoom") {
                InspectorSegmentedPicker(
                    "Style",
                    selection: Binding(
                        get: { editor.editSettings.zoomPreset },
                        set: { editor.applyZoomPreset($0) }
                    ),
                    options: ZoomPreset.allCases
                ) { $0.label }
                InspectorHint("Zooms in on each click. A new style rebuilds the auto zooms; the ones you added stay.")
                Button {
                    editor.applyZoomPreset(editor.editSettings.zoomPreset)
                } label: {
                    Label("Rebuild Auto Zooms", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            InspectorSection("Camera movement") {
                InspectorToggle(
                    title: "Spring motion",
                    subtitle: "Eases in and settles like a real camera.",
                    isOn: editor.settingBinding(\.exportStyle.springCameraEnabled, actionName: "Spring Camera")
                )
                InspectorToggle(
                    title: "Motion blur",
                    subtitle: "Softens fast zooms and pans.",
                    isOn: editor.settingBinding(\.exportStyle.motionBlurEnabled, actionName: "Motion Blur")
                )
            }
            CutMotionSection(editor: editor)
            CameraMovesSection(editor: editor)
            InspectorSection("Zooms") {
                Text("\(editor.keyframes.count) zooms · \(manualCount) added by you")
                    .font(DS.Typeface.body)
                InspectorHint("Press Z and drag over the preview to zoom somewhere new, or drag along the Zoom track. Select a zoom to change where it points.")
            }
        }
    }
}

// MARK: - Audio

struct AudioInspector: View {
    @ObservedObject var editor: ProjectEditor

    /// Recordings from before system audio only had a microphone track.
    private var roles: [AudioTrackRole] {
        let saved = editor.project.metadata.audioTrackRoles
        return saved.isEmpty ? [.microphone] : saved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            levels
            CutAudioSection(editor: editor)
        }
    }

    private var levels: some View {
        InspectorSection("Levels") {
            if roles.contains(.microphone) {
                EditorSlider(
                    editor: editor,
                    title: "Microphone",
                    actionName: "Microphone Volume",
                    value: editor.settingBinding(\.audio.microphoneVolume, actionName: "Microphone Volume", continuous: true),
                    range: AudioMixSettings.volumeRange
                ) { $0 < 0.005 ? "Muted" : "\(Int(($0 * 100).rounded()))%" }
            }
            if roles.contains(.systemAudio) {
                EditorSlider(
                    editor: editor,
                    title: "System audio",
                    actionName: "System Audio Volume",
                    value: editor.settingBinding(\.audio.systemAudioVolume, actionName: "System Audio Volume", continuous: true),
                    range: AudioMixSettings.volumeRange
                ) { $0 < 0.005 ? "Muted" : "\(Int(($0 * 100).rounded()))%" }
            }
            InspectorHint("Sped-up clips keep their pitch.")
        }
    }
}
