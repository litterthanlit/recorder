import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export settings, progress and result, as a sheet on the editor window.
struct ExportSheet: View {
    @ObservedObject var editor: ProjectEditor
    @Environment(\.dismiss) private var dismiss
    @State private var preferences = ExportPreferences.load()
    @State private var fileName = ""
    @State private var startedAt: Date?

    private var options: ExportOptions { preferences.options }
    private var duration: TimeInterval { editor.outputDuration }
    private var canvasSize: CGSize { editor.exportOutputSize }
    private var outputSize: CGSize { options.outputSize(canvas: canvasSize) }
    private var frameRate: Int { options.outputFrameRate(source: editor.project.metadata.fps) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .padding(DS.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 500)
        .interactiveDismissDisabled(editor.isExporting)
        .onAppear {
            if fileName.isEmpty {
                fileName = defaultFileName
            }
            if !ExportOptions.allows(options.format, duration: duration) {
                preferences.options.format = .mp4
            }
        }
        .onChange(of: editor.state) { _, state in
            if case let .exported(url) = state, preferences.revealWhenDone {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private var defaultFileName: String {
        ExportNaming.baseName(
            template: preferences.fileNameTemplate,
            name: editor.displayName,
            date: editor.project.metadata.createdAt
        )
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Export")
                .font(DS.Typeface.largeTitle)
            Text("\(Int(outputSize.width)) × \(Int(outputSize.height)) · \(frameRate) fps · \(Timecode.short(duration))")
                .font(DS.Typeface.footnote.monospacedDigit())
                .foregroundStyle(DS.Palette.secondaryText)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        switch editor.state {
        case let .exporting(progress):
            progressView(progress)
        case let .exported(url):
            doneView(url)
        case let .failed(message):
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typeface.footnote)
                    .foregroundStyle(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                settingsView
            }
        case .editing:
            settingsView
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            switch editor.state {
            case .exporting:
                Spacer()
                Button("Cancel Export", role: .cancel) {
                    editor.cancelExport()
                }
                .buttonStyle(SecondaryButtonStyle())
            case .exported:
                Button("Export Another") {
                    editor.dismissExportResult()
                    fileName = defaultFileName
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Done") {
                    editor.dismissExportResult()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            case .editing, .failed:
                Button("Cancel") {
                    editor.dismissExportResult()
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Spacer()
                if let bytes = options.estimatedBytes(size: outputSize, fps: frameRate, duration: duration) {
                    Text("About \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(DS.Typeface.footnote)
                        .foregroundStyle(DS.Palette.secondaryText)
                }
                Button {
                    startExport()
                } label: {
                    Label(preferences.askForLocation ? "Export…" : "Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!ExportOptions.allows(options.format, duration: duration))
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }

    // MARK: - Settings

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            InspectorLabeled("Format") {
                FormatPicker(selection: $preferences.options.format, duration: duration)
            }

            HStack(alignment: .top, spacing: DS.Spacing.lg) {
                if options.format.usesQuality {
                    InspectorLabeled("Quality") {
                        Picker("Quality", selection: $preferences.options.quality) {
                            ForEach(ExportQuality.allCases) { quality in
                                Text(quality.label).tag(quality)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                InspectorLabeled("Frame rate") {
                    if options.format == .gif {
                        Text("\(ExportOptions.gifFrameRate) fps")
                            .font(DS.Typeface.body)
                            .foregroundStyle(DS.Palette.secondaryText)
                            .frame(height: 22)
                    } else {
                        Picker("Frame rate", selection: $preferences.options.frameRate) {
                            Text("\(editor.project.metadata.fps) (as recorded)").tag(Int?.none)
                            ForEach(ExportOptions.frameRateChoices, id: \.self) { rate in
                                Text("\(rate)").tag(Int?.some(rate))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            InspectorLabeled("Size") {
                Picker("Size", selection: editor.settingBinding(\.canvas.resolution, actionName: "Change Resolution")) {
                    ForEach(OutputResolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if options.format == .gif, outputSize != canvasSize {
                    InspectorHint("GIFs are scaled down to \(Int(ExportOptions.gifMaximumWidth)) pixels wide.")
                }
            }

            InspectorLabeled("Name") {
                HStack(spacing: 4) {
                    TextField("File name", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                    Text(".\(options.format.fileExtension)")
                        .font(DS.Typeface.body.monospaced())
                        .foregroundStyle(DS.Palette.secondaryText)
                }
            }

            InspectorLabeled("Save to") {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "folder")
                        .foregroundStyle(DS.Palette.secondaryText)
                    Text(Self.displayPath(preferences.folderURL))
                        .font(DS.Typeface.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Spacing.xs)
                    Button("Change…") { chooseFolder() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .opacity(preferences.askForLocation ? 0.45 : 1)
                Toggle("Ask where to save each time", isOn: $preferences.askForLocation)
                    .font(DS.Typeface.footnote)
                Toggle("Show in Finder when done", isOn: $preferences.revealWhenDone)
                    .font(DS.Typeface.footnote)
            }
        }
    }

    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.folderURL
        panel.prompt = "Choose"
        panel.message = "Choose where exports are saved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.folderPath = url.path
        preferences.askForLocation = false
    }

    private func startExport() {
        preferences.save()
        let fileExtension = options.format.fileExtension
        let name = ExportNaming.sanitized(fileName) + "." + fileExtension
        let destination: URL
        if preferences.askForLocation {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = preferences.folderURL
            panel.canCreateDirectories = true
            if let type = UTType(filenameExtension: fileExtension) {
                panel.allowedContentTypes = [type]
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        } else {
            destination = ExportNaming.uniqueURL(in: preferences.folderURL, fileName: name) {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        startedAt = Date()
        editor.export(options: options, to: destination)
    }

    // MARK: - Progress and result

    private func progressView(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Exporting…")
                    .font(DS.Typeface.title)
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(DS.Typeface.title.monospacedDigit())
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Export progress")
                .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            Text(remainingText(progress))
                .font(DS.Typeface.footnote)
                .foregroundStyle(DS.Palette.secondaryText)
        }
        .padding(.vertical, DS.Spacing.md)
    }

    private func remainingText(_ progress: Double) -> String {
        guard let startedAt, progress > 0.03, progress < 1 else { return "Rendering frames" }
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = elapsed * (1 - progress) / progress
        return remaining < 60 ? "About \(Int(remaining.rounded(.up))) seconds left" : "About \(Int((remaining / 60).rounded(.up))) minutes left"
    }

    private func doneView(_ url: URL) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 64, height: 64)
                .onDrag {
                    NSItemProvider(contentsOf: url) ?? NSItemProvider()
                }
                .help("Drag the video into any app")
                .accessibilityLabel("Exported file, drag into another app")
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Label("Exported", systemImage: "checkmark.circle.fill")
                    .font(DS.Typeface.title)
                    .foregroundStyle(DS.Palette.success)
                Text(url.lastPathComponent)
                    .font(DS.Typeface.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([url as NSURL])
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .help("Copy the file, ready to paste into a chat or an email")
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.vertical, DS.Spacing.sm)
    }
}

/// Four format tiles; GIF is unavailable for long edits.
private struct FormatPicker: View {
    @Binding var selection: ExportFormat
    let duration: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(ExportFormat.allCases) { format in
                    tile(format)
                }
            }
            if !ExportOptions.allows(.gif, duration: duration) {
                InspectorHint("GIF is for short loops: trim the video to \(Int(ExportOptions.gifMaximumDuration)) seconds or less.")
            }
        }
    }

    private func tile(_ format: ExportFormat) -> some View {
        let isSelected = selection == format
        let isAllowed = ExportOptions.allows(format, duration: duration)
        let border: Color = isSelected ? DS.Palette.accent : Color.primary.opacity(0.1)
        let fill: Color = isSelected ? DS.Palette.accent.opacity(0.1) : DS.Palette.raisedSurface
        return Button {
            selection = format
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(format.label)
                    .font(DS.Typeface.headline)
                Text(format.detail)
                    .font(DS.Typeface.caption)
                    .foregroundStyle(DS.Palette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(DS.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .strokeBorder(border, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAllowed)
        .opacity(isAllowed ? 1 : 0.45)
        .accessibilityLabel("\(format.label), \(format.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
