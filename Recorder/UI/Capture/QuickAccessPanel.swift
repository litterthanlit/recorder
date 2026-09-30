import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// CleanShot-style cards in the corner of the screen after each take: a thumbnail with
/// Edit, Export, Copy and Show in Finder. Once exported, the card can be dragged straight
/// into Slack, Mail or a browser. Cards stack (newest at the bottom) and close by
/// themselves after a few seconds unless hovered or busy.
@MainActor
final class QuickAccessController {
    private var cards: [QuickAccessCard] = []
    private let library: ProjectLibrary
    private let settings: SettingsStore
    var onEdit: ((RecorderProject) -> Void)?

    private static let maxCards = 3
    private static let cardSize = CGSize(width: 300, height: 232)

    init(library: ProjectLibrary, settings: SettingsStore) {
        self.library = library
        self.settings = settings
    }

    func show(_ project: RecorderProject) {
        let model = QuickAccessModel(project: project, autoDismiss: settings.settings.quickAccessAutoDismiss)
        let card = QuickAccessCard(model: model)
        model.onEdit = { [weak self, weak card] in
            guard let self, let card else { return }
            self.dismiss(card)
            self.onEdit?(card.model.project)
        }
        model.onClose = { [weak self, weak card] in
            guard let self, let card else { return }
            self.dismiss(card)
        }
        model.onExported = { [weak self] in
            self?.library.refresh()
        }
        cards.append(card)
        while cards.count > Self.maxCards, let oldest = cards.first {
            dismiss(oldest)
        }
        layout(animated: false)
        card.panel.orderFrontRegardless()
        layout(animated: true)
    }

    private func dismiss(_ card: QuickAccessCard) {
        card.model.cancelTimer()
        card.panel.orderOut(nil)
        cards.removeAll { $0 === card }
        layout(animated: true)
    }

    /// Bottom-left of the main screen, stacked upwards.
    private func layout(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        for (index, card) in cards.reversed().enumerated() {
            let origin = CGPoint(
                x: visible.minX + 20,
                y: visible.minY + 20 + CGFloat(index) * (Self.cardSize.height + 12)
            )
            let frame = CGRect(origin: origin, size: Self.cardSize)
            if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    card.panel.animator().setFrame(frame, display: true)
                }
            } else {
                card.panel.setFrame(frame, display: true)
            }
        }
    }
}

private final class QuickAccessCard {
    let model: QuickAccessModel
    let panel: NSPanel

    @MainActor
    init(model: QuickAccessModel) {
        self.model = model
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 300, height: 232)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickAccessView(model: model))
    }
}

@MainActor
final class QuickAccessModel: ObservableObject {
    enum ExportState: Equatable {
        case none
        case exporting(Double)
        case exported(URL)
        case failed(String)
    }

    let project: RecorderProject
    @Published private(set) var exportState: ExportState
    @Published private(set) var thumbnail: NSImage?
    @Published var isHovering = false {
        didSet { isHovering ? cancelTimer() : scheduleDismiss() }
    }
    @Published private(set) var copied = false

    var onEdit: (() -> Void)?
    var onClose: (() -> Void)?
    var onExported: (() -> Void)?

    private let autoDismiss: Bool
    private var dismissTask: Task<Void, Never>?

    init(project: RecorderProject, autoDismiss: Bool) {
        self.project = project
        self.autoDismiss = autoDismiss
        exportState = FileManager.default.fileExists(atPath: project.exportURL.path) ? .exported(project.exportURL) : .none
        Task { await loadThumbnail() }
        scheduleDismiss()
    }

    func export(thenCopy copy: Bool = false) {
        if case .exporting = exportState { return }
        cancelTimer()
        exportState = .exporting(0)
        Task {
            do {
                let url = try await ExportService.export(project) { [weak self] progress in
                    self?.exportState = .exporting(progress)
                }
                exportState = .exported(url)
                onExported?()
                if copy {
                    copyToPasteboard(url)
                }
            } catch {
                exportState = .failed(error.localizedDescription)
            }
            scheduleDismiss()
        }
    }

    /// Copies the exported file (exporting first if needed), ready to paste into a chat
    /// or an email.
    func copy() {
        if case let .exported(url) = exportState {
            copyToPasteboard(url)
        } else {
            export(thenCopy: true)
        }
    }

    func reveal() {
        if case let .exported(url) = exportState {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([project.bundleURL])
        }
    }

    func cancelTimer() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func scheduleDismiss() {
        cancelTimer()
        guard autoDismiss, !isHovering else { return }
        if case .exporting = exportState { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.onClose?()
        }
    }

    private func loadThumbnail() async {
        let generator = AVAssetImageGeneratorBox(url: project.videoURL)
        let midpoint = min(1, max(0, project.metadata.duration / 2))
        thumbnail = await generator.image(at: midpoint)
    }
}

/// Makes a thumbnail off the main actor.
private struct AVAssetImageGeneratorBox {
    let url: URL

    func image(at seconds: TimeInterval) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 400)
        guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else {
            return nil
        }
        return NSImage(cgImage: result.image, size: .zero)
    }
}

private struct QuickAccessView: View {
    @ObservedObject var model: QuickAccessModel

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            thumbnail
            actions
        }
        .padding(DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large + 2, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large + 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .onHover { model.isHovering = $0 }
        .padding(4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let image = ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black.opacity(0.85)
                if let thumbnail = model.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                if case let .exporting(progress) = model.exportState {
                    VStack(spacing: DS.Spacing.xs) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 160)
                        Text("Exporting… \(Int(progress * 100))%")
                            .font(DS.Typeface.caption.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .padding(DS.Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(Color.black.opacity(0.6)))
                }
            }
            .frame(height: 158)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
            .onTapGesture(count: 2) { model.onEdit?() }

            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(6)
            .opacity(model.isHovering ? 1 : 0)
            .accessibilityLabel("Close")
        }

        if case let .exported(url) = model.exportState {
            // Drag the finished video anywhere a file can go.
            image
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Drag the video into another app")
        } else {
            image
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            actionButton("Edit", icon: "slider.horizontal.3") { model.onEdit?() }
            switch model.exportState {
            case .none, .failed:
                actionButton("Export", icon: "square.and.arrow.up") { model.export() }
            case .exporting:
                actionButton("Export", icon: "square.and.arrow.up") {}
                    .disabled(true)
            case .exported:
                actionButton("Re-export", icon: "arrow.clockwise") { model.export() }
            }
            actionButton(model.copied ? "Copied" : "Copy", icon: model.copied ? "checkmark" : "doc.on.doc") {
                model.copy()
            }
            actionButton("Show", icon: "folder") { model.reveal() }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(DS.Typeface.caption)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        }
        .buttonStyle(QuickActionStyle())
        .accessibilityLabel(title)
    }
}

private struct QuickActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuickActionBody(configuration: configuration)
    }

    private struct QuickActionBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering ? DS.Palette.accent : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(configuration.isPressed ? DS.Palette.pressed : (isHovering ? DS.Palette.hover : .clear))
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}
