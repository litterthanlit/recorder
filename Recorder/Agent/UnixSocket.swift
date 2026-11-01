import Foundation

/// Unix-domain stream sockets: the private channel between `Trace --mcp` and the app.
enum UnixSocket {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// `sockaddr_un` holds 103 bytes of path.
        case pathTooLong(String)
        /// Another process is already listening there.
        case alreadyServing(String)
        /// A system call failed, with its `errno`.
        case system(String, Int32)

        var description: String {
            switch self {
            case let .pathTooLong(path):
                return "Socket path is too long: \(path)"
            case let .alreadyServing(path):
                return "Another copy of Trace is already serving agents at \(path)"
            case let .system(call, code):
                return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// The longest path a socket address holds (it ends with a NUL).
    static var maximumPathLength: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    }

    /// Connects to the socket at `path`.
    static func connect(to path: String) throws -> Int32 {
        let address = try makeAddress(path)
        let descriptor = try makeSocket()
        let result = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.system("connect", code)
        }
        return descriptor
    }

    /// Whether something is listening at `path` right now.
    static func isListening(at path: String) -> Bool {
        guard let descriptor = try? connect(to: path) else { return false }
        Darwin.close(descriptor)
        return true
    }

    /// Listens at `path`, readable and writable by this user only. A socket file left
    /// behind by a crash is replaced; a live one is not (`alreadyServing`).
    static func listen(at path: String) throws -> Int32 {
        let address = try makeAddress(path)
        if FileManager.default.fileExists(atPath: path) {
            if isListening(at: path) {
                throw Failure.alreadyServing(path)
            }
            unlink(path)
        }
        let descriptor = try makeSocket()
        let bound = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.system("bind", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, 8) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw Failure.system("listen", code)
        }
        return descriptor
    }

    /// The user ID of the process at the other end of a connected socket.
    static func peerUserID(_ descriptor: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
    }

    /// Not inherited by child processes, and a write to a closed peer fails with `EPIPE`
    /// instead of killing the process with `SIGPIPE`.
    static func configure(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Failure.system("socket", errno)
        }
        configure(descriptor)
        return descriptor
    }

    private static func makeAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumPathLength else {
            throw Failure.pathTooLong(path)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return address
    }
}
