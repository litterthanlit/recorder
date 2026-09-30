import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import QuartzCore

@MainActor
final class CameraBubbleOverlay {
    private var panel: NSPanel?
    private var previewHost: NSView?
    private var processedLayer: CALayer?

    /// Called with the corner the bubble was dragged to.
    var onPositionChange: ((CameraBubblePosition) -> Void)?
    private var size: CameraBubbleSize = .medium

    var windowID: UInt32? {
        guard let panel else { return nil }
        return UInt32(panel.windowNumber)
    }

    func show(
        previewLayer: AVCaptureVideoPreviewLayer,
        position: CameraBubblePosition,
        size: CameraBubbleSize,
        on screen: NSScreen? = nil
    ) {
        self.size = size
        let host = makePanel(position: position, on: screen)
        previewLayer.frame = host.bounds
        previewLayer.cornerRadius = host.bounds.width / 2
        previewLayer.masksToBounds = true
        host.layer?.addSublayer(previewLayer)
        processedLayer = nil
    }

    /// Shows a bubble that displays processed camera frames (virtual backgrounds).
    func showProcessedPreview(position: CameraBubblePosition, size: CameraBubbleSize, on screen: NSScreen? = nil) {
        self.size = size
        let host = makePanel(position: position, on: screen)
        let layer = CALayer()
        layer.frame = host.bounds
        layer.contentsGravity = .resizeAspectFill
        layer.contentsScale = host.window?.backingScaleFactor ?? 2
        host.layer?.addSublayer(layer)
        processedLayer = layer
    }

    /// Shows a frame prepared by `CameraPreviewRenderer` (off the main thread).
    func updateProcessedFrame(_ image: CGImage) {
        processedLayer?.contents = image
    }

    func hide() {
        if let host = previewHost {
            host.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        panel?.orderOut(nil)
        panel = nil
        previewHost = nil
        processedLayer = nil
    }

    @discardableResult
    private func makePanel(position: CameraBubblePosition, on preferredScreen: NSScreen?) -> NSView {
        hide()

        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame
        let diameter = size.livePoints
        let padding: CGFloat = 28
        let origin = bubbleOrigin(
            in: screenFrame,
            diameter: diameter,
            padding: padding,
            position: position
        )

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false

        // Drag the bubble anywhere; it snaps to the nearest corner when let go.
        let host = BubbleDragView(frame: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter)))
        host.onDrop = { [weak self, weak panel] in
            guard let self, let panel else { return }
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            let position = CameraBubblePosition.nearest(to: center, in: screenFrame)
            let origin = self.bubbleOrigin(in: screenFrame, diameter: diameter, padding: padding, position: position)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
                panel.animator().setFrameOrigin(origin)
            }
            self.onPositionChange?(position)
        }
        host.wantsLayer = true
        host.layer?.cornerRadius = diameter / 2
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 3
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        host.layer?.backgroundColor = NSColor.black.cgColor

        panel.contentView = host
        panel.orderFrontRegardless()

        self.panel = panel
        self.previewHost = host
        return host
    }

    private func bubbleOrigin(
        in screenFrame: CGRect,
        diameter: CGFloat,
        padding: CGFloat,
        position: CameraBubblePosition
    ) -> CGPoint {
        switch position {
        case .bottomRight:
            return CGPoint(
                x: screenFrame.maxX - diameter - padding,
                y: screenFrame.minY + padding
            )
        case .bottomLeft:
            return CGPoint(
                x: screenFrame.minX + padding,
                y: screenFrame.minY + padding
            )
        case .topRight:
            return CGPoint(
                x: screenFrame.maxX - diameter - padding,
                y: screenFrame.maxY - diameter - padding
            )
        case .topLeft:
            return CGPoint(
                x: screenFrame.minX + padding,
                y: screenFrame.maxY - diameter - padding
            )
        }
    }
}

/// The bubble's content view: moves its window with the pointer and reports the drop.
private final class BubbleDragView: NSView {
    var onDrop: (() -> Void)?
    private var grabOffset: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        grabOffset = CGPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let grabOffset else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard grabOffset != nil else { return }
        grabOffset = nil
        NSCursor.pop()
        onDrop?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// Turns processed camera frames into small preview images for the on-screen bubble.
///
/// Runs on the camera queue, not the main thread (which also services the click-tracking
/// event tap), and scales the frame down to bubble size before reading it back. While a
/// frame is still waiting to be shown, new ones are skipped rather than queued.
final class CameraPreviewRenderer: @unchecked Sendable {
    /// The largest on-screen bubble is 240 pt, so 2x that is plenty.
    static let maxPixelSize: CGFloat = 480

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var isFramePending = false

    /// Returns `false` if the previous frame hasn't been shown yet.
    func beginFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFramePending else { return false }
        isFramePending = true
        return true
    }

    func endFrame() {
        lock.lock()
        isFramePending = false
        lock.unlock()
    }

    func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let shortSide = min(extent.width, extent.height)
        guard shortSide > 0 else { return nil }

        let scale = min(1, Self.maxPixelSize / shortSide)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }
}
