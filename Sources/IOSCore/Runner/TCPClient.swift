import Foundation

/// Blocking request/response over TCP: sends one line, reads until a NUL byte.
/// POSIX sockets so IPv6 CoreDevice tunnel addresses work the same as 127.0.0.1.
enum TCPClient {
    static func request(host: String, port: UInt16, line: String, timeout: TimeInterval) throws -> Data {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else {
            throw IOSError.runnerUnreachable(host: host, port: port, reason: "cannot resolve address")
        }
        defer { freeaddrinfo(results) }

        var fd: Int32 = -1
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate {
            fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { break }
                close(fd)
                fd = -1
            }
            candidate = info.pointee.ai_next
        }
        guard fd >= 0 else {
            throw IOSError.runnerUnreachable(host: host, port: port, reason: String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw IOSError.runnerUnreachable(host: host, port: port, reason: "send failed") }
            sent += n
        }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 { throw IOSError.runnerUnreachable(host: host, port: port, reason: errno == EAGAIN ? "timed out" : String(cString: strerror(errno))) }
            if n == 0 { break }
            reply.append(contentsOf: buffer[0..<n])
            if buffer[n - 1] == 0 {
                reply.removeLast()
                break
            }
        }
        return reply
    }
}
