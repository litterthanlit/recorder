import AppKit
import AVFoundation
import CoreVideo
import QuartzCore

@MainActor
final class CameraBubbleOverlay {
    private var panel: NSPanel?
    private var previewHost: NSView?
    private var processedLayer: CALayer?
    private let imageConverter = CameraBackgroundProcessor()

    var windowID: UInt32? {
        guard let panel else { return nil }
        return UInt32(panel.windowNumber)
    }

    func show(previewLayer: AVCaptureVideoPreviewLayer, position: CameraBubblePosition) {
        let host = makePanel(position: position)
        previewLayer.frame = host.bounds
        previewLayer.cornerRadius = host.bounds.width / 2
        previewLayer.masksToBounds = true
        host.layer?.addSublayer(previewLayer)
        processedLayer = nil
    }

    /// Shows a bubble that displays processed camera frames (virtual backgrounds).
    func showProcessedPreview(position: CameraBubblePosition) {
        let host = makePanel(position: position)
        let layer = CALayer()
        layer.frame = host.bounds
        layer.contentsGravity = .resizeAspectFill
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        host.layer?.addSublayer(layer)
        processedLayer = layer
    }

    func updateProcessedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let processedLayer else { return }
        guard let cgImage = imageConverter.makeCGImage(from: pixelBuffer) else { return }
        processedLayer.contents = cgImage
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
    private func makePanel(position: CameraBubblePosition) -> NSView {
        hide()

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame
        let diameter: CGFloat = 168
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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false

        let host = NSView(frame: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter)))
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
