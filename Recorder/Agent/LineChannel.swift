import Foundation

/// Splits a byte stream into messages, one per line: the framing of MCP's stdio transport
/// and of the agent bridge. A line ends with "\n"; a "\r" before it is dropped and empty
/// lines are skipped.
struct LineBuffer {
    enum Failure: Error, Equatable {
        /// A line grew past the limit; what was buffered is dropped.
        case lineTooLong
    }

    let maximumLineLength: Int
    private var pending = Data()
    /// How much of `pending` is known to hold no newline, so it isn't searched again.
    private var scanned = 0

    init(maximumLineLength: Int = 32 * 1024 * 1024) {
        self.maximumLineLength = maximumLineLength
    }

    /// Adds `bytes` and returns the lines they complete, without their line endings.
    mutating func append(_ bytes: Data) throws -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        var lineStart = pending.startIndex
        var searchFrom = pending.startIndex + scanned
        while searchFrom < pending.endIndex, let newline = pending[searchFrom...].firstIndex(of: 0x0A) {
            var lineEnd = newline
            if lineEnd > lineStart, pending[lineEnd - 1] == 0x0D {
                lineEnd -= 1
            }
            if lineEnd > lineStart {
                lines.append(pending.subdata(in: lineStart..<lineEnd))
            }
            lineStart = newline + 1
            searchFrom = lineStart
        }
        if lineStart > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<lineStart)
        }
        scanned = pending.count
        if pending.count > maximumLineLength {
            pending.removeAll()
            scanned = 0
            throw Failure.lineTooLong
        }
        return lines
    }
}

/// Blocking reads and writes on a file descriptor (stdin, stdout, a socket).
enum FileDescriptorIO {
    /// Writes all of `data`, retrying partial and interrupted writes. `false` when the
    /// other end is gone.
    @discardableResult
    static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    /// Waits for bytes and returns up to `maximum` of them; `nil` at end of file or on an
    /// error.
    static func read(from descriptor: Int32, maximum: Int = 65_536) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, maximum)
            }
            if count > 0 {
                return Data(buffer[0..<count])
            }
            if count < 0, errno == EINTR {
                continue
            }
            return nil
        }
    }
}
