import AppKit
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case selection
    case background
    case cursor
    case camera
    case zoom
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: return "Selection"
        case .background: return "Background"
        case .cursor: return "Cursor & Keys"
        case .camera: return "Camera"
        case .zoom: return "Zoom"
        case .audio: return "Audio"
        }
    }

    var icon: String {
        switch self {
        case .selection: return "slider.horizontal.3"
        case .background: return "paintpalette"
        case .cursor: return "cursorarrow.rays"
        case .camera: return "video"
        case .zoom: return "plus.magnifyingglass"
        case .audio: return "speaker.wave.2"
        }
    }
}

/// The editor's right sidebar: the look of the video, in tabs, and the settings of
/// whatever is selected on the timeline.
struct InspectorView: View {
    @ObservedObject var editor: ProjectEditor
    @State private var tab: InspectorTab = .background
    /// Where to go back to when the selection is cleared.
    @State private var tabBeforeSelection: InspectorTab = .background

    static let width: CGFloat = 300

    private var tabs: [InspectorTab] {
        editor.selection == nil ? InspectorTab.allCases.filter { $0 != .selection } : InspectorTab.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView {
                content
                    .padding(DS.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A control wider than the column would otherwise draw over the canvas.
            .clipped()
        }
        .frame(width: Self.width)
        .background(DS.Palette.surface)
        .onChange(of: editor.selection) { _, newSelection in
            if newSelection != nil {
                if tab != .selection {
                    tabBeforeSelection = tab
                }
                tab = .selection
            } else if tab == .selection {
                tab = tabBeforeSelection
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { item in
                InspectorTabButton(tab: item, isSelected: tab == item) {
                    if item != .selection {
                        tabBeforeSelection = item
                    }
                    tab = item
                }
            }
        }
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector sections")
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .selection:
            SelectionInspector(editor: editor)
        case .background:
            BackgroundInspector(editor: editor)
        case .cursor:
            CursorInspector(editor: editor)
        case .camera:
            CameraInspector(editor: editor)
        case .zoom:
            ZoomInspector(editor: editor)
        case .audio:
            AudioInspector(editor: editor)
        }
    }
}

private struct InspectorTabButton: View {
    let tab: InspectorTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let tint: Color = isSelected ? DS.Palette.accent : DS.Palette.secondaryText
        let fill: Color = isSelected ? DS.Palette.accent.opacity(0.14) : .clear
        return Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 26)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Looks

/// The saved looks, shared by every editor window.
@MainActor
final class StyleLibraryModel: ObservableObject {
    static let shared = StyleLibraryModel()

    @Published private(set) var library: StyleLibrary

    private init() {
        library = StyleLibraryStore.load()
    }

    func save(_ preset: StylePreset) {
        library.save(preset)
        persist()
    }

    func delete(_ id: UUID) {
        library.delete(id: id)
        persist()
    }

    /// The look new recordings start with; `nil` is the app's default.
    func setDefault(_ id: UUID?) {
        library.defaultPresetID = id
        persist()
    }

    private func persist() {
        do {
            try StyleLibraryStore.save(library)
        } catch {
            Log.editor.error("Couldn't save looks: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Built-in and saved looks: apply one, save the current one, and pick what new
/// recordings start with.
struct LooksSection: View {
    @ObservedObject var editor: ProjectEditor
    @ObservedObject private var looks = StyleLibraryModel.shared
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        InspectorSection("Look") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(looks.library.allPresets) { preset in
                        LookChip(
                            preset: preset,
                            isDefault: looks.library.defaultPresetID == preset.id
                        ) {
                            editor.applyLook(preset)
                        }
                        .contextMenu { menu(for: preset) }
                    }
                }
                // Room for the default look's star, which sits over the chip's corner.
                .padding(.vertical, DS.Spacing.xxs)
                .padding(.trailing, DS.Spacing.xxs)
            }

            HStack(spacing: DS.Spacing.xs) {
                Button {
                    newName = ""
                    isNaming = true
                } label: {
                    Label("Save Look…", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                .popover(isPresented: $isNaming, arrowEdge: .bottom) {
                    SaveLookPopover(name: $newName) {
                        saveCurrentLook()
                    }
                }

                Spacer(minLength: 0)

                Menu {
                    Toggle("Trace Default", isOn: defaultBinding(nil))
                    Divider()
                    ForEach(looks.library.allPresets) { preset in
                        Toggle(preset.name, isOn: defaultBinding(preset.id))
                    }
                } label: {
                    Text("New takes: \(defaultLookName)")
                        .font(DS.Typeface.footnote)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The look new recordings start with")
            }
        }
    }

    /// Shortened so a long saved name can't push the menu past the column.
    private var defaultLookName: String {
        let name = looks.library.defaultPreset?.name ?? "Default"
        return name.count > 16 ? "\(name.prefix(15))…" : name
    }

    private func defaultBinding(_ id: UUID?) -> Binding<Bool> {
        Binding(
            get: { looks.library.defaultPresetID == id },
            set: { isOn in
                if isOn {
                    looks.setDefault(id)
                }
            }
        )
    }

    @ViewBuilder
    private func menu(for preset: StylePreset) -> some View {
        Button("Apply") { editor.applyLook(preset) }
        Button("Use for New Recordings") { looks.setDefault(preset.id) }
        if !looks.library.isBuiltIn(preset) {
            Divider()
            Button("Delete Look", role: .destructive) { looks.delete(preset.id) }
        }
    }

    private func saveCurrentLook() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        looks.save(StylePreset(name: name, from: editor.editSettings))
        isNaming = false
    }
}

private struct LookChip: View {
    let preset: StylePreset
    let isDefault: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.xxs) {
                ZStack(alignment: .topTrailing) {
                    thumbnail
                    if isDefault {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(DS.Palette.accent))
                            .offset(x: 4, y: -4)
                    }
                }
                Text(preset.name)
                    .font(DS.Typeface.caption)
                    .lineLimit(1)
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
        .help("Apply the \(preset.name) look")
        .accessibilityLabel("\(preset.name) look\(isDefault ? ", used for new recordings" : "")")
        .accessibilityHint("Applies this look")
    }

    /// The background with a small window on it, showing the look's padding, corners and
    /// shadow. The padding is exaggerated: at true scale the window covered nearly the whole
    /// chip, and every look read as a white tile.
    private var thumbnail: some View {
        let style = preset.style
        let inset: CGFloat = style.backgroundEnabled ? 6 + 40 * style.paddingRatio : 0
        let corner: CGFloat = style.backgroundEnabled ? min(5, style.cornerRadius / 4) : 0
        let window = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return ZStack {
            BackgroundSwatch(style: style.background)
            window
                .fill(Color.white.opacity(0.94))
                .overlay(window.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(style.shadowEnabled && style.backgroundEnabled ? 0.28 : 0), radius: 2, y: 1)
                .padding(inset)
        }
        .frame(width: 64, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }
}

private struct SaveLookPopover: View {
    @Binding var name: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Save Look")
                .font(DS.Typeface.headline)
            Text("Saves the background, frame, cursor, keystroke, camera, canvas and zoom settings.")
                .font(DS.Typeface.caption)
                .foregroundStyle(DS.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)
            HStack {
                Spacer()
                Button("Save", action: onSave)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: 260)
    }
}
