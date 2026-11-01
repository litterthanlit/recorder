import Foundation

/// A connected socket carrying one JSON message per line in each direction. Incoming
/// lines arrive on the socket's own serial queue; `send` can be called from any thread.
final class LineSocket: @unchecked Sendable {
    /// The descriptor, and the lock that keeps a write and the close apart (so a write
    /// can never land on a reused descriptor number). Shared with the read source's
    /// cancel handler, which may run after the socket itself is gone.
    private final class Channel: @unchecked Sendable {
        let descriptor: Int32
        private let lock = NSLock()
        private var isOpen = true

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        func write(_ data: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isOpen else { return false }
            return FileDescriptorIO.writeAll(data, to: descriptor)
        }

        func closeDescriptor() {
            lock.lock()
            defer { lock.unlock() }
            guard isOpen else { return }
            isOpen = false
            Darwin.close(descriptor)
        }
    }

    /// Bytes read so far that don't make a whole line yet (only touched on the queue).
    private final class Reader: @unchecked Sendable {
        var buffer: LineBuffer

        init(maximumLineLength: Int) {
            buffer = LineBuffer(maximumLineLength: maximumLineLength)
        }
    }

    private let channel: Channel
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var isClosing = false

    init(descriptor: Int32, label: String = "app.hypher.recorder.agent.socket") {
        channel = Channel(descriptor: descriptor)
        queue = DispatchQueue(label: label)
        UnixSocket.setNonBlocking(descriptor)
    }

    deinit {
        close()
    }

    /// Delivers each incoming line to `onLine` until the other end closes, a line is too
    /// long, or `close()` is called; then `onClose` runs once. Both run on the socket's
    /// queue.
    func start(
        maximumLineLength: Int = 32 * 1024 * 1024,
        onLine: @escaping (Data) -> Void,
        onClose: @escaping () -> Void
    ) {
        stateLock.lock()
        guard !isClosing, source == nil else {
            stateLock.unlock()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: channel.descriptor, queue: queue)
        self.source = source
        stateLock.unlock()

        let channel = self.channel
        let reader = Reader(maximumLineLength: maximumLineLength)
        source.setEventHandler { [weak self] in
            while true {
                switch FileDescriptorIO.readAvailable(from: channel.descriptor) {
                case let .data(chunk):
                    guard let lines = try? reader.buffer.append(chunk) else {
                        self?.close()
                        return
                    }
                    lines.forEach(onLine)
                case .wouldBlock:
                    return
                case .end:
                    self?.close()
                    return
                }
            }
        }
        source.setCancelHandler {
            channel.closeDescriptor()
            onClose()
        }
        source.resume()
    }

    /// Writes one message and its newline. `false` once the socket is closed.
    @discardableResult
    func send(_ message: JSONValue) -> Bool {
        channel.write(message.line())
    }

    /// Stops reading and closes the descriptor (safe to call more than once).
    func close() {
        stateLock.lock()
        guard !isClosing else {
            stateLock.unlock()
            return
        }
        isClosing = true
        let source = self.source
        stateLock.unlock()

        if let source {
            // The cancel handler closes the descriptor once reading has stopped.
            source.cancel()
        } else {
            channel.closeDescriptor()
        }
    }
}
