import CoreGraphics
import Foundation

/// Floating-point comparison for tests (exact `==` on computed doubles is flaky).
func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

func isClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1e-6) -> Bool {
    isClose(a.minX, b.minX, tolerance: tolerance)
        && isClose(a.minY, b.minY, tolerance: tolerance)
        && isClose(a.width, b.width, tolerance: tolerance)
        && isClose(a.height, b.height, tolerance: tolerance)
}

/// A fresh directory under the system temp folder, removed by `cleanup()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ string: String, to relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: fileURL)
    }
}
