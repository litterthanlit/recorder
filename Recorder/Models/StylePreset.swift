import Foundation

/// A saved look (background, frame, cursor, keystrokes, camera styling, canvas and zoom
/// feel) to reuse across recordings. One can be the default for new recordings.
struct StylePreset: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var style: ExportStyle
    var camera: CameraOverlayStyle
    var canvas: CanvasSpec
    var zoomPreset: ZoomPreset

    init(
        id: UUID = UUID(),
        name: String,
        style: ExportStyle = ExportStyle(),
        camera: CameraOverlayStyle = CameraOverlayStyle(),
        canvas: CanvasSpec = CanvasSpec(),
        zoomPreset: ZoomPreset = .demo
    ) {
        self.id = id
        self.name = name
        self.style = style
        self.camera = camera
        self.canvas = canvas
        self.zoomPreset = zoomPreset
    }

    /// The look of `settings`, to save as a preset.
    init(name: String, from settings: ProjectEditSettings) {
        self.init(
            name: name,
            style: settings.exportStyle,
            camera: settings.camera,
            canvas: settings.canvas,
            zoomPreset: settings.zoomPreset
        )
    }

    /// Applies the look. Whether the camera shows stays as it is (a take without a camera
    /// has nothing to show), and so does the cursor smoothing choice made when recording.
    func apply(to settings: inout ProjectEditSettings) {
        let cameraVisible = settings.camera.isVisible
        let smoothing = settings.exportStyle.cursorSmoothingEnabled
        settings.exportStyle = style
        settings.exportStyle.cursorSmoothingEnabled = smoothing
        settings.camera = camera
        settings.camera.isVisible = cameraVisible
        settings.canvas = canvas
        settings.zoomPreset = zoomPreset
    }

    /// Looks that ship with the app.
    static let builtIn: [StylePreset] = {
        var midnight = ExportStyle()
        midnight.background = BackgroundStyle(kind: .wallpaper, wallpaper: .midnight)

        var studio = ExportStyle()
        studio.background = BackgroundStyle(kind: .wallpaper, wallpaper: .snow)
        studio.cornerRadius = 14

        var vivid = ExportStyle()
        vivid.background = BackgroundStyle(kind: .wallpaper, wallpaper: .aurora)
        vivid.cornerRadius = 20
        vivid.paddingRatio = 0.12

        var minimal = ExportStyle()
        minimal.background = BackgroundStyle(kind: .none)
        minimal.clickRipplesEnabled = false

        var social = ExportStyle()
        social.background = BackgroundStyle(kind: .wallpaper, wallpaper: .candy)
        social.cornerRadius = 24
        social.paddingRatio = 0.06

        return [
            StylePreset(id: UUID(uuidString: "5A1D0001-0000-4000-8000-000000000001")!, name: "Midnight", style: midnight),
            StylePreset(id: UUID(uuidString: "5A1D0001-0000-4000-8000-000000000002")!, name: "Studio Light", style: studio, zoomPreset: .subtle),
            StylePreset(id: UUID(uuidString: "5A1D0001-0000-4000-8000-000000000003")!, name: "Vivid", style: vivid, zoomPreset: .punch),
            StylePreset(id: UUID(uuidString: "5A1D0001-0000-4000-8000-000000000004")!, name: "Minimal", style: minimal, zoomPreset: .subtle),
            StylePreset(
                id: UUID(uuidString: "5A1D0001-0000-4000-8000-000000000005")!,
                name: "Vertical Social",
                style: social,
                canvas: CanvasSpec(aspect: .portrait, resolution: .hd1080),
                zoomPreset: .punch
            )
        ]
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        style = (try? container.decodeIfPresent(ExportStyle.self, forKey: .style)) ?? ExportStyle()
        camera = (try? container.decodeIfPresent(CameraOverlayStyle.self, forKey: .camera)) ?? CameraOverlayStyle()
        canvas = (try? container.decodeIfPresent(CanvasSpec.self, forKey: .canvas)) ?? CanvasSpec()
        zoomPreset = (try? container.decodeIfPresent(ZoomPreset.self, forKey: .zoomPreset)) ?? .demo
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, style, camera, canvas, zoomPreset
    }
}

/// The user's saved looks and which one new recordings start with.
struct StyleLibrary: Codable, Equatable {
    var presets: [StylePreset] = []
    /// Built-in or saved; `nil` means the app's default look.
    var defaultPresetID: UUID?

    init(presets: [StylePreset] = [], defaultPresetID: UUID? = nil) {
        self.presets = presets
        self.defaultPresetID = defaultPresetID
    }

    /// Adds `preset`, or replaces the saved one with the same ID. Built-in looks can't
    /// be replaced.
    mutating func save(_ preset: StylePreset) {
        guard !isBuiltIn(preset) else { return }
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
    }

    /// Removes a saved look (and stops using it as the default).
    mutating func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        if defaultPresetID == id {
            defaultPresetID = nil
        }
    }

    /// Built-in looks followed by the user's own.
    var allPresets: [StylePreset] {
        StylePreset.builtIn + presets
    }

    var defaultPreset: StylePreset? {
        defaultPresetID.flatMap { id in allPresets.first { $0.id == id } }
    }

    func isBuiltIn(_ preset: StylePreset) -> Bool {
        StylePreset.builtIn.contains { $0.id == preset.id }
    }
}

extension StyleLibrary {
    private enum CodingKeys: String, CodingKey {
        case presets, defaultPresetID
    }

    /// A damaged preset is skipped rather than losing the others.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = (try? container.decodeIfPresent([LossyPreset].self, forKey: .presets)) ?? []
        presets = lossy.compactMap(\.preset)
        defaultPresetID = try? container.decodeIfPresent(UUID.self, forKey: .defaultPresetID)
    }

    private struct LossyPreset: Decodable {
        let preset: StylePreset?

        init(from decoder: Decoder) throws {
            preset = try? StylePreset(from: decoder)
        }
    }
}

/// Saved looks live in `~/Library/Application Support/Trace/styles.json`.
enum StyleLibraryStore {
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent(Brand.name, isDirectory: true)
            .appendingPathComponent("styles.json")
    }

    /// The saved library, or an empty one if there's none or it can't be read.
    static func load(from url: URL = defaultURL) -> StyleLibrary {
        guard let data = try? Data(contentsOf: url) else { return StyleLibrary() }
        do {
            return try JSONDecoder().decode(StyleLibrary.self, from: data)
        } catch {
            Log.library.error("Couldn't read saved styles: \(error.localizedDescription, privacy: .public)")
            return StyleLibrary()
        }
    }

    static func save(_ library: StyleLibrary, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}

extension ProjectEditSettings {
    /// Settings for a new take: the default look (if one is set), then what was chosen
    /// while recording (cursor smoothing, where and how big the camera was).
    static func forNewTake(
        timeline: EditTimeline,
        look: StylePreset?,
        cursorSmoothing: Bool,
        cameraPosition: CameraBubblePosition,
        cameraSize: CameraBubbleSize
    ) -> ProjectEditSettings {
        var settings = ProjectEditSettings()
        look?.apply(to: &settings)
        settings.setTimeline(timeline)
        settings.exportStyle.cursorSmoothingEnabled = cursorSmoothing
        settings.camera.position = cameraPosition
        settings.camera.size = cameraSize
        // The size picked for the live bubble wins over a saved slider size.
        settings.camera.customSize = nil
        return settings
    }
}
