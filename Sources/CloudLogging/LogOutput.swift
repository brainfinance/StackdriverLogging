import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A file descriptor that receives whole log lines. Writes are serialized so lines never interleave.
final class LogOutput: Sendable {
    static let standardOutput = LogOutput(fileDescriptor: STDOUT_FILENO)

    private let fileDescriptor: Int32
    private let lock = Mutex<Void>(())

    /// The caller keeps ownership of `fileDescriptor`; it is not closed when the output is released.
    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func write(_ bytes: [UInt8]) {
        self.lock.withLock { _ in
            bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = systemWrite(self.fileDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += written
                }
            }
        }
    }
}

#if canImport(Darwin)
private let systemWrite = Darwin.write
#elseif canImport(Glibc)
private let systemWrite = Glibc.write
#elseif canImport(Musl)
private let systemWrite = Musl.write
#endif
