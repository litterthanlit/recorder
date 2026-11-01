import AppKit
import SwiftUI

/// What the selector picked.
enum CaptureSelection: Equatable {
    case area(CaptureArea)
    case window(UInt32)
    case display(UInt32)
}

/// CleanShot-style picker for what to record: drag out an area (with handles, a size
/// readout and shape presets), hover and click a window, or click a display. One
/// transparent panel covers each screen. ⏎ records, ⎋ cancels, Space switches between
/// area and window, arrow keys nudge the area (⇧ for 10 pt).
@MainActor
final class CaptureSelector: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case area
        case window
        case display

        var id: String { rawValue }

        var label: String {
            switch self {
            case .area: return "Area"
            case .window: return "Window"
            case .display: return "Display"
            }
        }

        var icon: String {
            switch self {
            case .area: return "rectangle.dashed"
            case .window: return "macwindow"
            case .display: return "display"
            }
        }
    }

    struct HoveredWindow: Equatable {
        let windowID: UInt32
        /// Global display points, top-left origin.
        let bounds: CGRect
    }

    @Published var mode: Mode = .area
    @Published var selection: CaptureArea?
    @Published var preset: AreaPreset = .free
    @Published private(set) var hoveredWindow: HoveredWindow?
    @Published private(set) var hoveredDisplayID: UInt32?
    /// The screen the toolbar sits on (where the selection or the pointer is).
    @Published private(set) var activeDisplayID: UInt32?

    private var panels: [SelectionPanel] = []
    private var completion: ((CaptureSelection?) -> Void)?
    private var windows: [WindowSnapshot] = []
    private var lastWindowRefresh: TimeInterval = 0

    var isActive: Bool {
        !panels.isEmpty
    }

    func begin(
        mode: Mode,
        lastArea: CaptureArea?,
        preset: AreaPreset,
        completion: @escaping (CaptureSelection?) -> Void
    ) {
        finish(nil)
        self.mode = mode
        self.preset = preset
        self.completion = completion
        hoveredWindow = nil
        hoveredDisplayID = nil
        refreshWindows(force: true)

        // Offer the last area again if its display is still there.
        if let lastArea, NSScreen.screen(forDisplayID: lastArea.displayID) != nil {
            selection = lastArea
        } else {
            selection = nil
        }

        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        activeDisplayID = selection?.displayID ?? mouseScreen?.displayIdentifier

        for screen in NSScreen.screens {
            let panel = SelectionPanel(screen: screen, selector: self)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        NSApp.activate()
        let keyPanel = panels.first { $0.displayID == activeDisplayID } ?? panels.first
        keyPanel?.makeKey()
        updatePointer(to: mouse)
    }

    /// Closes the panels and reports `result` (nil: cancelled).
    func finish(_ result: CaptureSelection?) {
        guard !panels.isEmpty || completion != nil else { return }
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    func cancel() {
        finish(nil)
    }

    /// Records what's picked now (⏎ or the Record button).
    func confirm() {
        switch mode {
        case .area:
            guard let selection, selection.rect.width >= AreaSelection.minimumSize.width / 2 else {
                NSSound.beep()
                return
            }
            finish(.area(selection))
        case .window:
            guard let hoveredWindow else {
                NSSound.beep()
                return
            }
            finish(.window(hoveredWindow.windowID))
        case .display:
            guard let displayID = hoveredDisplayID ?? activeDisplayID else { return }
            finish(.display(displayID))
        }
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        updatePointer(to: NSEvent.mouseLocation)
        redraw()
    }

    func applyPreset(_ preset: AreaPreset) {
        self.preset = preset
        guard var area = selection, let screen = NSScreen.screen(forDisplayID: area.displayID) else { return }
        area.rect = AreaSelection.apply(
            preset,
            to: area.rect,
            scale: screen.backingScaleFactor,
            bounds: CGRect(origin: .zero, size: screen.frame.size)
        )
        selection = area
        redraw()
    }

    func setSelection(_ area: CaptureArea?) {
        selection = area
        if let area {
            activeDisplayID = area.displayID
        }
        redraw()
    }

    /// Size of the selection in recorded pixels.
    var selectionPixelSize: CGSize? {
        guard let selection, let screen = NSScreen.screen(forDisplayID: selection.displayID) else { return nil }
        let pixels = CaptureGeometry.pixelSize(points: selection.rect.size, scale: screen.backingScaleFactor)
        return CGSize(width: pixels.width, height: pixels.height)
    }

    /// Tracks the pointer (Cocoa global coordinates) for window and display hover.
    func updatePointer(to location: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return }
        let displayID = screen.displayIdentifier
        hoveredDisplayID = displayID
        if mode != .area || selection == nil {
            activeDisplayID = displayID
        }

        if mode == .window {
            refreshWindows(force: false)
            let global = Self.globalTopLeft(location)
            let hit = WindowHitTest.frontmostWindow(
                at: global,
                frontToBack: windows,
                excludingOwner: ProcessInfo.processInfo.processIdentifier
            )
            hoveredWindow = hit.map { HoveredWindow(windowID: $0.windowID, bounds: $0.bounds) }
        } else {
            hoveredWindow = nil
        }
        redraw()
    }

    func redraw() {
        for panel in panels {
            panel.selectionView.needsDisplay = true
            panel.selectionView.needsLayout = true
        }
    }

    /// Cocoa global point (bottom-left origin) to global display points (top-left
    /// origin), the space window bounds and `CGDisplayBounds` use.
    static func globalTopLeft(_ point: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private func refreshWindows(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastWindowRefresh > 0.5 else { return }
        lastWindowRefresh = now
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        windows = list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width > 40, bounds.height > 40
            else { return nil }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            return WindowSnapshot(windowID: number.uint32Value, layer: layer, bounds: bounds, ownerPID: pid)
        }
    }
}

// MARK: - Panel

private final class SelectionPanel: NSPanel {
    let displayID: UInt32
    let selectionView: SelectionView

    init(screen: NSScreen, selector: CaptureSelector) {
        displayID = screen.displayIdentifier
        selectionView = SelectionView(selector: selector, displayID: screen.displayIdentifier, screen: screen)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = selectionView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Drawing and interaction

private final class SelectionView: NSView {
    private let selector: CaptureSelector
    private let displayID: UInt32
    private let scale: CGFloat
    private let toolbar: NSHostingView<CaptureSelectorToolbar>
    private var trackingArea: NSTrackingArea?

    private enum Drag {
        case drawing(start: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(AreaSelection.Handle)
    }
    private var drag: Drag?

    init(selector: CaptureSelector, displayID: UInt32, screen: NSScreen) {
        self.selector = selector
        self.displayID = displayID
        scale = screen.backingScaleFactor
        toolbar = NSHostingView(rootView: CaptureSelectorToolbar(selector: selector))
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addSubview(toolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var bounds0: CGRect {
        CGRect(origin: .zero, size: bounds.size)
    }

    private var localSelection: CGRect? {
        guard let selection = selector.selection, selection.displayID == displayID else { return nil }
        return selection.rect
    }

    /// This display's top-left corner in global display points.
    private var displayOrigin: CGPoint {
        CGDisplayBounds(displayID).origin
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let isActiveScreen = selector.activeDisplayID == displayID
        toolbar.isHidden = !isActiveScreen
        guard isActiveScreen else { return }

        let size = toolbar.fittingSize
        let margin: CGFloat = 14
        var origin = CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 72)
        if selector.mode == .area, let rect = localSelection {
            origin.x = min(max(rect.midX - size.width / 2, margin), bounds.width - size.width - margin)
            if rect.maxY + margin + size.height < bounds.height - margin {
                origin.y = rect.maxY + margin
            } else if rect.minY - margin - size.height > margin {
                origin.y = rect.minY - margin - size.height
            } else {
                origin.y = rect.maxY - margin - size.height
            }
        }
        toolbar.frame = CGRect(origin: origin, size: size)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.38)
        let accent = NSColor.controlAccentColor

        switch selector.mode {
        case .area:
            let hole = localSelection
            drawDim(dim, excluding: hole)
            if let hole {
                drawSelection(hole, accent: accent)
            } else if selector.activeDisplayID == displayID {
                drawHint("Drag to select an area · Space for windows · Esc to cancel")
            }

        case .window:
            if let hovered = selector.hoveredWindow {
                let local = hovered.bounds.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
                if local.intersects(bounds0) {
                    drawDim(dim, excluding: local)
                    accent.withAlphaComponent(0.18).setFill()
                    NSBezierPath(rect: local).fill()
                    let border = NSBezierPath(rect: local.insetBy(dx: 1.5, dy: 1.5))
                    border.lineWidth = 3
                    accent.setStroke()
                    border.stroke()
                } else {
                    drawDim(dim, excluding: nil)
                }
            } else {
                drawDim(dim, excluding: nil)
                if selector.hoveredDisplayID == displayID {
                    drawHint("Click a window to record it")
                }
            }

        case .display:
            if selector.hoveredDisplayID == displayID {
                accent.withAlphaComponent(0.16).setFill()
                bounds0.fill()
                let border = NSBezierPath(rect: bounds0.insetBy(dx: 3, dy: 3))
                border.lineWidth = 6
                accent.setStroke()
                border.stroke()
                drawHint("Click to record this display")
            } else {
                drawDim(dim, excluding: nil)
            }
        }
    }

    private func drawDim(_ color: NSColor, excluding hole: CGRect?) {
        let path = NSBezierPath(rect: bounds0)
        if let hole {
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
        }
        color.setFill()
        path.fill()
    }

    private func drawSelection(_ rect: CGRect, accent: NSColor) {
        let outline = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        outline.stroke()

        let dashes = NSBezierPath(rect: rect.insetBy(dx: -1.5, dy: -1.5))
        dashes.lineWidth = 1.5
        dashes.setLineDash([6, 4], count: 2, phase: 0)
        accent.setStroke()
        dashes.stroke()

        for handle in AreaSelection.Handle.allCases {
            let center = handle.point(in: rect)
            let knob = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            let path = NSBezierPath(ovalIn: knob)
            NSColor.white.setFill()
            path.fill()
            path.lineWidth = 1.5
            accent.setStroke()
            path.stroke()
        }

        let pixels = CaptureGeometry.pixelSize(points: rect.size, scale: scale)
        let label = "\(pixels.width) × \(pixels.height)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let pill = CGRect(
            x: rect.minX,
            y: rect.minY - textSize.height - 12 >= 0 ? rect.minY - textSize.height - 12 : rect.minY + 6,
            width: textSize.width + 12,
            height: textSize.height + 6
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        label.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attributes)
    }

    private func drawHint(_ text: String) {
        let string = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = string.size(withAttributes: attributes)
        let pill = CGRect(
            x: (bounds.width - size.width) / 2 - 16,
            y: bounds.height * 0.42 - size.height / 2 - 9,
            width: size.width + 32,
            height: size.height + 18
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: CGPoint(x: pill.minX + 16, y: pill.minY + 9), withAttributes: attributes)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        selector.updatePointer(to: NSEvent.mouseLocation)
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: CGPoint) {
        guard selector.mode == .area else {
            NSCursor.pointingHand.set()
            return
        }
        switch localSelection.flatMap({ AreaSelection.hitTest(point, rect: $0) }) {
        case .handle(let handle):
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        case .body:
            NSCursor.openHand.set()
        case nil:
            NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        switch selector.mode {
        case .window:
            selector.updatePointer(to: NSEvent.mouseLocation)
            selector.confirm()
            return
        case .display:
            selector.finish(.display(displayID))
            return
        case .area:
            break
        }

        if event.clickCount == 2, let rect = localSelection, rect.contains(point) {
            selector.confirm()
            return
        }

        switch localSelection.flatMap({ AreaSelection.hitTest(point, rect: $0) }) {
        case .handle(let handle):
            drag = .resizing(handle)
        case .body:
            drag = .moving(start: point, original: localSelection ?? .zero)
            NSCursor.closedHand.set()
        case nil:
            drag = .drawing(start: point)
            selector.setSelection(CaptureArea(displayID: displayID, rect: CGRect(origin: point, size: .zero)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard selector.mode == .area, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let aspect = selector.preset.aspectRatio
        let rect: CGRect
        switch drag {
        case .drawing(let start):
            rect = AreaSelection.rect(from: start, to: point, aspect: aspect, bounds: bounds0)
        case .moving(let start, let original):
            rect = AreaSelection.move(
                original,
                by: CGSize(width: point.x - start.x, height: point.y - start.y),
                within: bounds0
            )
        case .resizing(let handle):
            guard let current = localSelection else { return }
            rect = AreaSelection.resize(current, handle: handle, to: point, aspect: aspect, bounds: bounds0)
        }
        selector.setSelection(CaptureArea(displayID: displayID, rect: rect))
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard case .drawing = drag, let rect = localSelection else { return }
        if rect.width < 8 || rect.height < 8 {
            // A click, not a drag: clear the selection.
            selector.setSelection(nil)
        } else if rect.width < AreaSelection.minimumSize.width || rect.height < AreaSelection.minimumSize.height {
            let grown = AreaSelection.resize(
                rect,
                handle: .bottomRight,
                to: CGPoint(x: rect.minX + AreaSelection.minimumSize.width, y: rect.minY + AreaSelection.minimumSize.height),
                aspect: selector.preset.aspectRatio,
                bounds: bounds0
            )
            selector.setSelection(CaptureArea(displayID: displayID, rect: grown))
        }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        switch keyCode {
        case KeyNames.Code.escape:
            selector.cancel()
        case KeyNames.Code.returnKey, 0x4C:
            selector.confirm()
        case KeyNames.Code.space:
            selector.setMode(selector.mode == .window ? .area : .window)
        case KeyNames.Code.leftArrow, KeyNames.Code.rightArrow, KeyNames.Code.upArrow, KeyNames.Code.downArrow:
            nudge(keyCode: keyCode, by: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(keyCode: UInt32, by step: CGFloat) {
        guard selector.mode == .area, let rect = localSelection else { return }
        var delta = CGSize.zero
        switch keyCode {
        case KeyNames.Code.leftArrow: delta.width = -step
        case KeyNames.Code.rightArrow: delta.width = step
        case KeyNames.Code.upArrow: delta.height = -step
        default: delta.height = step
        }
        selector.setSelection(CaptureArea(displayID: displayID, rect: AreaSelection.move(rect, by: delta, within: bounds0)))
    }
}

// MARK: - Toolbar

struct CaptureSelectorToolbar: View {
    @ObservedObject var selector: CaptureSelector

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            modePicker
            if selector.mode == .area {
                areaControls
            }
            Divider()
                .frame(height: 18)
                .overlay(Color.white.opacity(0.2))
            actions
        }
        .padding(DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        )
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(CaptureSelector.Mode.allCases) { mode in
                ModeButton(mode: mode, isSelected: selector.mode == mode) {
                    selector.setMode(mode)
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private var presetBinding: Binding<AreaPreset> {
        Binding(
            get: { selector.preset },
            set: { selector.applyPreset($0) }
        )
    }

    @ViewBuilder
    private var areaControls: some View {
        Menu {
            Picker("Shape", selection: presetBinding) {
                ForEach(AreaPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(selector.preset.label, systemImage: "aspectratio")
                .font(DS.Typeface.footnote.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.white)
        .accessibilityLabel("Area shape, \(selector.preset.label)")

        if let size = selector.selectionPixelSize {
            SelectionSizeLabel(width: Int(size.width), height: Int(size.height))
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.xs) {
            Button("Cancel") { selector.cancel() }
                .buttonStyle(.plain)
                .font(DS.Typeface.footnote.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .padding(.horizontal, 6)

            Button {
                selector.confirm()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(.foreground).frame(width: 8, height: 8)
                    Text("Record")
                }
            }
            .buttonStyle(PrimaryButtonStyle(.recording))
            .disabled(selector.mode == .area && selector.selection == nil)
            .help("Record (⏎)")
        }
    }
}

private struct SelectionSizeLabel: View {
    let width: Int
    let height: Int

    var body: some View {
        Text("\(width) × \(height)")
            .font(DS.Typeface.timecode)
            .foregroundStyle(Color.white.opacity(0.7))
            .accessibilityLabel("\(width) by \(height) pixels")
    }
}

private struct ModeButton: View {
    let mode: CaptureSelector.Mode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let foreground: Color = isSelected ? .white : Color.white.opacity(0.75)
        let fill: Color = isSelected ? DS.Palette.accentFill : .clear
        return Button(action: action) {
            Label(mode.label, systemImage: mode.icon)
                .labelStyle(.titleAndIcon)
                .font(DS.Typeface.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
