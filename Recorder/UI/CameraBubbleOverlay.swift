import AppKit
import AVFoundation
import QuartzCore

@MainActor
final class CameraBubbleOverlay {
    private var panel: NSPanel?
    private var previewHost: NSView?

    var windowID: UInt32? {
        guard let panel else { return nil }
        return UInt32(panel.windowNumber)
    }

    func show(previewLayer: AVCaptureVideoPreviewLayer, position: CameraBubblePosition) {
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

        previewLayer.frame = host.bounds
        previewLayer.cornerRadius = diameter / 2
        previewLayer.masksToBounds = true
        host.layer?.addSublayer(previewLayer)

        panel.contentView = host
        panel.orderFrontRegardless()

        self.panel = panel
        self.previewHost = host
    }

    func hide() {
        if let host = previewHost {
            host.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        panel?.orderOut(nil)
        panel = nil
        previewHost = nil
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
