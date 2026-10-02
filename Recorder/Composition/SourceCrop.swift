import CoreGraphics
import Foundation

/// Cropping the recording to part of the screen, like an app's window, before anything
/// else: the crop is what the video shows at rest, zooms push in within it, and the
/// canvas's Auto shape and Source size follow it. Rects are normalized with a
/// bottom-left origin, like zoom centres and blur boxes.
enum SourceCrop {
    /// The whole recording.
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// A crop is at least this much of the recording on each side.
    static let minimumSide: CGFloat = 0.05
    /// Closer than this to every edge is the whole recording.
    static let edgeTolerance: CGFloat = 0.002

    /// `rect` kept inside the recording and at least `minimumSide` across; `nil` when
    /// it's the whole recording or isn't a rect at all.
    static func sanitized(_ rect: CGRect) -> CGRect? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        let clipped = rect.standardized.intersection(full)
        guard !clipped.isNull else { return nil }
        let width = min(max(clipped.width, minimumSide), 1)
        let height = min(max(clipped.height, minimumSide), 1)
        let result = CGRect(
            x: min(max(clipped.minX, 0), 1 - width),
            y: min(max(clipped.minY, 0), 1 - height),
            width: width,
            height: height
        )
        let wholeRecording = result.minX <= edgeTolerance && result.minY <= edgeTolerance
            && result.maxX >= 1 - edgeTolerance && result.maxY >= 1 - edgeTolerance
        return wholeRecording ? nil : result
    }

    /// What the video shows at rest: `crop`, or the whole recording.
    static func base(_ crop: CGRect?) -> CGRect {
        crop.flatMap { sanitized($0) } ?? full
    }

    /// Pixel size of the picture once cropped.
    static func contentSize(source: CGSize, crop: CGRect?) -> CGSize {
        let shown = Self.base(crop)
        return CGSize(width: source.width * shown.width, height: source.height * shown.height)
    }

    /// The rect of `shape` (height over width, normalized) around `rect`'s centre that
    /// holds all of it, kept inside the recording; one too big for the recording is shrunk
    /// to the largest of its shape that fits. `nil` for a rect or shape that isn't one.
    static func fitted(_ rect: CGRect, shape: CGFloat) -> CGRect? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              shape.isFinite, shape > 0
        else { return nil }
        let standard = rect.standardized
        var width = max(standard.width, minimumSide)
        var height = width * shape
        if abs(height - standard.height) <= 1e-9 {
            // Already that shape: keep it exactly, so fitting twice changes nothing.
            height = standard.height
        } else if height < standard.height {
            height = standard.height
            width = height / shape
        }
        if width > 1 {
            width = 1
            height = shape
        }
        if height > 1 {
            height = 1
            width = 1 / shape
        }
        let x = width == standard.width ? standard.minX : standard.midX - width / 2
        let y = height == standard.height ? standard.minY : standard.midY - height / 2
        return CGRect(
            x: min(max(x, 0), 1 - width),
            y: min(max(y, 0), 1 - height),
            width: width,
            height: height
        )
    }

    /// The smallest box around all of `rects`, grown by `margin` (of the recording) on
    /// each side; `nil` without rects.
    static func union(_ rects: [CGRect], margin: CGFloat = 0) -> CGRect? {
        let valid = rects.filter { !$0.isNull && !$0.isEmpty && $0.width.isFinite && $0.height.isFinite }
        guard let first = valid.first else { return nil }
        let joined = valid.dropFirst().reduce(first) { $0.union($1) }
        return joined.insetBy(dx: -margin, dy: -margin)
    }
}

extension ProjectEditSettings {
    /// What the video shows at rest when the crop holds still: the crop, or the whole
    /// recording.
    var cropBase: CGRect {
        SourceCrop.base(sourceCrop)
    }

    /// The crop over the take: still, or following a window.
    var cropMotion: CropMotion {
        CropMotion(crop: sourceCrop, path: cropPath)
    }

    /// What the video shows at rest at `time` (source seconds): where the crop is then.
    func cropBase(at time: TimeInterval) -> CGRect {
        cropMotion.base(at: time)
    }

    /// Pixel size of the recording once cropped, for a recording of `source` pixels.
    func contentSize(source: CGSize) -> CGSize {
        SourceCrop.contentSize(source: source, crop: sourceCrop)
    }

    /// The canvas size in pixels: its shape and size, with Auto and Source following the
    /// cropped picture.
    func canvasPixelSize(source: CGSize) -> CGSize {
        canvas.pixelSize(source: contentSize(source: source))
    }
}
