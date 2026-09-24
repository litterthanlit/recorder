import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import QuartzCore
import SwiftUI

struct CompositorPreviewView: NSViewRepresentable {
    @ObservedObject var editor: ProjectEditor

    func makeNSView(context: Context) -> CompositorPreviewHost {
        let host = CompositorPreviewHost(player: editor.player, cameraPlayer: editor.cameraPlayer)
        host.apply(keyframes: editor.keyframes, settings: editor.renderSettings)
        return host
    }

    func updateNSView(_ nsView: CompositorPreviewHost, context: Context) {
        nsView.apply(keyframes: editor.keyframes, settings: editor.renderSettings)
    }
}

/// Shows the editor preview by compositing the current video frame with the same
/// renderer the export uses, once per display refresh.
///
/// Frames are rendered on a background queue into pooled, GPU-resident (IOSurface)
/// buffers and handed straight to an `AVSampleBufferDisplayLayer`, so they never
/// round-trip through the CPU. At most one frame is in flight: refresh ticks that arrive
/// while a frame is still rendering are dropped rather than queued, so a slow frame can't
/// make the picture fall further and further behind the audio.
final class CompositorPreviewHost: NSView {
    private let player: AVPlayer
    private let cameraPlayer: AVPlayer?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var cameraOutput: AVPlayerItemVideoOutput?
    private var itemStatusObserver: NSKeyValueObservation?
    private var displayLink: CVDisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?

    // Main thread only.
    private var appliedKeyframes: [ZoomKeyframe]?
    private var appliedSettings: CompositionRenderSettings?

    // Render queue only.
    private let renderQueue = DispatchQueue(label: "com.recorder.preview.render", qos: .userInteractive)
    private let renderer: CompositionRenderer
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCameraBuffer: CVPixelBuffer?
    private var lastRenderedSignature = 0
    private var lastRenderHostTime: CFTimeInterval = 0
    private var hasDeferredUpdate = false
    private var outputPool: CVPixelBufferPool?
    private var outputPoolWidth = 0
    private var outputPoolHeight = 0
    private var formatDescription: CMVideoFormatDescription?

    // Shared between the main thread, the display link thread, and the render queue.
    private let stateLock = NSLock()
    private var sharedPixelWidth = 0
    private var sharedPixelHeight = 0
    private var isRenderInFlight = false
    private var needsRender = true

    /// Preview refresh cap. ProMotion displays tick at 120 Hz; rendering every tick would
    /// double the work for no visible gain in a preview.
    private static let minimumFrameInterval: CFTimeInterval = 1.0 / 60.0
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    init(player: AVPlayer, cameraPlayer: AVPlayer?) {
        self.player = player
        self.cameraPlayer = cameraPlayer
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
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
        attachVideoOutput()
        attachCameraOutput()
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
        if let item = cameraPlayer?.currentItem, let cameraOutput {
            item.remove(cameraOutput)
        }
    }

    override func makeBackingLayer() -> CALayer {
        displayLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updatePixelSize()
            startDisplayLink()
            requestRender()
        } else {
            stopDisplayLink()
        }
    }

    override func layout() {
        super.layout()
        updatePixelSize()
        requestRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePixelSize()
        requestRender()
    }

    /// Called on every SwiftUI update of the editor, including every playhead tick, so
    /// it only touches the renderer when the keyframes or render settings changed.
    func apply(keyframes: [ZoomKeyframe], settings: CompositionRenderSettings) {
        guard keyframes != appliedKeyframes || settings != appliedSettings else { return }
        appliedKeyframes = keyframes
        appliedSettings = settings

        renderQueue.async { [renderer] in
            renderer.update(keyframes: keyframes, settings: settings)
        }
        requestRender()
    }

    // MARK: - Scheduling

    private func updatePixelSize() {
        let scale = window?.backingScaleFactor ?? 2
        let width = max(Int((bounds.width * scale).rounded()), 1)
        let height = max(Int((bounds.height * scale).rounded()), 1)
        stateLock.lock()
        sharedPixelWidth = width
        sharedPixelHeight = height
        stateLock.unlock()
    }

    /// Renders the next frame even if nothing time-related changed (settings, layout).
    private func requestRender() {
        stateLock.lock()
        needsRender = true
        stateLock.unlock()
        scheduleRender()
    }

    /// Called from the display link thread on every refresh, and after state changes.
    /// Drops the request if a frame is already being rendered.
    fileprivate func scheduleRender() {
        stateLock.lock()
        if isRenderInFlight {
            stateLock.unlock()
            return
        }
        isRenderInFlight = true
        stateLock.unlock()

        renderQueue.async { [weak self] in
            self?.renderOnQueue()
        }
    }

    // MARK: - Rendering (render queue)

    private func renderOnQueue() {
        stateLock.lock()
        let forced = needsRender
        needsRender = false
        let pixelWidth = sharedPixelWidth
        let pixelHeight = sharedPixelHeight
        stateLock.unlock()

        defer {
            stateLock.lock()
            isRenderInFlight = false
            stateLock.unlock()
        }

        guard pixelWidth > 8, pixelHeight > 8, let videoOutput else { return }

        let now = CACurrentMediaTime()
        let time = videoOutput.itemTime(forHostTime: now)
        guard time.isValid else { return }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }

        var screenFrameChanged = false
        if videoOutput.hasNewPixelBuffer(forItemTime: time),
           let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastPixelBuffer = buffer
            screenFrameChanged = true
        } else if lastPixelBuffer == nil,
                  let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastPixelBuffer = buffer
            screenFrameChanged = true
        }
        guard let screenBuffer = lastPixelBuffer else { return }

        // Camera and screen share a timeline, so ask for the camera frame at the same time.
        var cameraFrameChanged = false
        if let cameraOutput {
            if cameraOutput.hasNewPixelBuffer(forItemTime: time),
               let cameraBuffer = cameraOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                lastCameraBuffer = cameraBuffer
                cameraFrameChanged = true
            } else if lastCameraBuffer == nil,
                      let cameraBuffer = cameraOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                lastCameraBuffer = cameraBuffer
                cameraFrameChanged = true
            }
        }

        // Zoom, cursor, and ripples animate with time even when the source frame is
        // unchanged (still screen), so time is part of what needs a redraw.
        let signature = pixelWidth &* 31 &+ pixelHeight &* 17 &+ Int((seconds * 1000).rounded())
        let hasChanges = forced || screenFrameChanged || cameraFrameChanged || hasDeferredUpdate
            || signature != lastRenderedSignature
        guard hasChanges else { return }

        if !forced, now - lastRenderHostTime < Self.minimumFrameInterval * 0.9 {
            hasDeferredUpdate = true
            return
        }

        guard let pool = outputPool(width: pixelWidth, height: pixelHeight),
              let rendered = try? renderer.renderFrame(
                  pixelBuffer: screenBuffer,
                  cameraBuffer: lastCameraBuffer,
                  at: seconds,
                  outputWidth: pixelWidth,
                  outputHeight: pixelHeight,
                  pool: pool
              )
        else { return }

        lastRenderedSignature = signature
        lastRenderHostTime = now
        hasDeferredUpdate = false

        if let colorSpace = Self.colorSpace {
            CVBufferSetAttachment(rendered, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        }
        display(rendered)
    }

    private func outputPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let outputPool, outputPoolWidth == width, outputPoolHeight == height {
            return outputPool
        }

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else {
            return nil
        }

        outputPool = pool
        outputPoolWidth = width
        outputPoolHeight = height
        formatDescription = nil
        return pool
    }

    private func display(_ pixelBuffer: CVPixelBuffer) {
        let needsNewDescription = formatDescription.map {
            !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer)
        } ?? true
        if needsNewDescription {
            var newDescription: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &newDescription
            )
            formatDescription = newDescription
        }
        guard let videoFormat = formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: videoFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == OSStatus(noErr), let sampleBuffer else {
            return
        }

        // Show each frame as soon as it's enqueued; the layer has no timebase to
        // schedule against.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            let displayImmediately: CFBoolean = kCFBooleanTrue
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(displayImmediately).toOpaque()
            )
        }

        if #available(macOS 14.0, *) {
            let videoRenderer = displayLayer.sampleBufferRenderer
            if videoRenderer.status == .failed {
                videoRenderer.flush()
            }
            videoRenderer.enqueue(sampleBuffer)
        } else {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    // MARK: - Player outputs

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
            self?.requestRender()
        }
    }

    private func attachCameraOutput() {
        guard let item = cameraPlayer?.currentItem else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        cameraOutput = output
    }

    // MARK: - Display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let target = DisplayLinkTarget(host: self)
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let target = Unmanaged<DisplayLinkTarget>.fromOpaque(context).takeUnretainedValue()
            target.host?.scheduleRender()
            return kCVReturnSuccess
        }, Unmanaged.passRetained(target).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
        displayLinkTarget = target
    }

    private func stopDisplayLink() {
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil

        if let displayLinkTarget {
            self.displayLinkTarget = nil
            // Balance the display link's retain a little later, in case a callback that
            // already read the pointer is still running.
            let retained = Unmanaged.passUnretained(displayLinkTarget)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                retained.release()
            }
        }
    }
}

/// What the display link holds on to. It references the view weakly, so the view can be
/// deallocated normally and late ticks do nothing.
private final class DisplayLinkTarget {
    weak var host: CompositorPreviewHost?

    init(host: CompositorPreviewHost) {
        self.host = host
    }
}
