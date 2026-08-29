import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import QuartzCore
import SwiftUI

struct CompositorPreviewView: NSViewRepresentable {
    @ObservedObject var editor: ProjectEditor

    func makeNSView(context: Context) -> CompositorPreviewHost {
        let host = CompositorPreviewHost(player: editor.player)
        host.apply(from: editor)
        return host
    }

    func updateNSView(_ nsView: CompositorPreviewHost, context: Context) {
        nsView.apply(from: editor)
    }
}

final class CompositorPreviewHost: NSView {
    private let player: AVPlayer
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CVDisplayLink?
    private var renderer: CompositionRenderer
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastRenderedSignature: Int = 0
    private let renderQueue = DispatchQueue(label: "com.recorder.preview.render")
    private var isDisplayLinkRunning = false
    private var itemStatusObserver: NSKeyValueObservation?

    init(player: AVPlayer) {
        self.player = player
        self.renderer = CompositionRenderer(
            keyframes: [],
            settings: CompositionRenderSettings(
                exportStyle: .runlyxDark,
                zoomPreset: .demo,
                cursorEvents: [],
                clickEvents: [],
                sourceWidth: 1920,
                sourceHeight: 1080,
                drawCursor: false
            )
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        attachVideoOutput()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDisplayLink()
        if let item = player.currentItem, let videoOutput {
            item.remove(videoOutput)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startDisplayLink()
            renderCurrentFrame(force: true)
        } else {
            stopDisplayLink()
        }
    }

    override func layout() {
        super.layout()
        renderCurrentFrame(force: true)
    }

    func apply(from editor: ProjectEditor) {
        let keyframes = editor.keyframes
        let settings = editor.renderSettings
        let playing = editor.isPlaying || editor.player.rate > 0
        if playing {
            startDisplayLink()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let time = self.player.currentTime()
            let pixelSize = self.pixelOutputSize()
            self.renderQueue.async {
                self.renderer.update(keyframes: keyframes, settings: settings)
                self.renderOnQueue(force: !playing, time: time, pixelSize: pixelSize)
            }
        }
    }

    private func attachVideoOutput() {
        guard let item = player.currentItem else { return }
        if let videoOutput {
            item.remove(videoOutput)
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        videoOutput = output
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            self?.renderCurrentFrame(force: true)
        }
    }

    private func startDisplayLink() {
        guard !isDisplayLinkRunning else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        displayLink = link
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let host = Unmanaged<CompositorPreviewHost>.fromOpaque(context).takeUnretainedValue()
            host.displayTick()
            return kCVReturnSuccess
        }, pointer)
        CVDisplayLinkStart(link)
        isDisplayLinkRunning = true
    }

    private func stopDisplayLink() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
        isDisplayLinkRunning = false
    }

    private func displayTick() {
        renderCurrentFrame(force: false)
    }

    private func renderCurrentFrame(force: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let time = self.player.currentTime()
            let pixelSize = self.pixelOutputSize()
            self.renderQueue.async {
                self.renderOnQueue(force: force, time: time, pixelSize: pixelSize)
            }
        }
    }

    private func renderOnQueue(
        force: Bool,
        time: CMTime,
        pixelSize: (width: Int, height: Int)
    ) {
        let seconds = CMTimeGetSeconds(time)
        guard pixelSize.width > 8, pixelSize.height > 8 else { return }

        if let output = videoOutput {
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                lastPixelBuffer = buffer
            } else if lastPixelBuffer == nil,
                      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                lastPixelBuffer = buffer
            }
        }

        guard let buffer = lastPixelBuffer else { return }

        let signature = pixelSize.width &* 31 &+ pixelSize.height &* 17 &+ Int((seconds * 1000).rounded())
        if !force, signature == lastRenderedSignature {
            return
        }
        lastRenderedSignature = signature

        guard let rendered = try? renderer.renderFrame(
            pixelBuffer: buffer,
            at: seconds.isFinite ? seconds : 0,
            outputWidth: pixelSize.width,
            outputHeight: pixelSize.height
        ) else {
            return
        }

        let image = CIImage(cvPixelBuffer: rendered)
        guard let cgImage = renderer.createCGImage(
            image,
            size: CGSize(width: pixelSize.width, height: pixelSize.height)
        ) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = cgImage
        }
    }

    private func pixelOutputSize() -> (width: Int, height: Int) {
        let scale = window?.backingScaleFactor ?? 2
        let width = max(Int((bounds.width * scale).rounded()), 1)
        let height = max(Int((bounds.height * scale).rounded()), 1)
        return (width, height)
    }
}
