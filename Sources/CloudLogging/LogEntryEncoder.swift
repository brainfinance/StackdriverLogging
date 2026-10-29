import Logging

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct Timestamp: Equatable {
    var seconds: Int
    var nanos: Int

    static func now() -> Timestamp {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return Timestamp(seconds: Int(time.tv_sec), nanos: Int(time.tv_nsec))
    }
}

// Field names Cloud Logging lifts out of the payload:
// https://docs.cloud.google.com/logging/docs/agent/logging/configuration#special-fields
struct LogEntryEncoder {
    private(set) var bytes: [UInt8] = []
    private let transform: CloudLoggingHandler.Transform?

    static let reservedKeys: Set<String> = [
        "severity", "message", "timestamp", "logging.googleapis.com/sourceLocation", "@type",
    ]

    init(transform: CloudLoggingHandler.Transform? = nil) {
        self.transform = transform
        self.bytes.reserveCapacity(512)
    }

    mutating func encode(_ event: LogEvent, metadata: Logger.Metadata, timestamp: Timestamp, reportErrors: Bool) {
        self.raw("{\"severity\":\"")
        self.raw(Self.severity(event.level))
        self.raw("\",\"message\":")
        self.string(event.message.description)
        self.raw(",\"timestamp\":{\"seconds\":")
        self.integer(timestamp.seconds)
        self.raw(",\"nanos\":")
        self.integer(timestamp.nanos)
        self.raw("},\"logging.googleapis.com/sourceLocation\":{\"file\":")
        self.string(event.file)
        self.raw(",\"line\":\"")
        self.integer(Int(event.line))
        self.raw("\",\"function\":")
        self.string(event.function)
        self.raw("}")

        if reportErrors && event.level >= .error {
            self.raw(",\"@type\":\"type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent\"")
        }
        if let error = event.error {
            self.raw(",\"error\":{\"type\":")
            // Private and local types reflect as `Module.(unknown context at $<address>).Name`; the address changes every run.
            self.string(String(reflecting: type(of: error)).replacing(/\(unknown context at \$[0-9a-fA-F]+\)\./, with: ""))
            self.raw(",\"message\":")
            self.string(String(describing: error))
            self.raw("}")
        }

        for (key, value) in metadata {
            if Self.reservedKeys.contains(key) || (event.error != nil && key == "error") { continue }
            guard let value = self.transformed(value) else { continue }
            self.raw(",")
            self.string(key)
            self.raw(":")
            self.value(value)
        }
        self.raw("}\n")
    }

    static func severity(_ level: Logger.Level) -> StaticString {
        switch level {
        case .trace, .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARNING"
        case .error: "ERROR"
        case .critical: "CRITICAL"
        }
    }

    private mutating func value(_ value: Logger.MetadataValue) {
        switch value {
        case .string(let text):
            self.string(text)
        case .stringConvertible(let convertible):
            switch convertible {
            case let flag as Bool:
                self.raw(flag ? "true" : "false")
            case let number as Int:
                self.integer(number)
            case let number as any BinaryInteger:
                self.bytes.append(contentsOf: String(describing: number).utf8)
            case let number as Double where number.isFinite:
                self.bytes.append(contentsOf: number.description.utf8)
            case let number as Float where number.isFinite:
                self.bytes.append(contentsOf: number.description.utf8)
            default:
                self.string(convertible.description)
            }
        case .array(let items):
            self.raw("[")
            var first = true
            for item in items {
                guard let item = self.transformed(item) else { continue }
                if !first { self.raw(",") }
                first = false
                self.value(item)
            }
            self.raw("]")
        case .dictionary(let entries):
            self.raw("{")
            var first = true
            for (key, item) in entries {
                guard let item = self.transformed(item) else { continue }
                if !first { self.raw(",") }
                first = false
                self.string(key)
                self.raw(":")
                self.value(item)
            }
            self.raw("}")
        }
    }

    private func transformed(_ value: Logger.MetadataValue) -> Logger.MetadataValue? {
        guard let transform = self.transform else { return value }
        return transform(value)
    }

    private mutating func raw(_ text: StaticString) {
        text.withUTF8Buffer { self.bytes.append(contentsOf: $0) }
    }

    private mutating func integer(_ number: Int) {
        self.bytes.append(contentsOf: String(number).utf8)
    }

    private mutating func string(_ text: String) {
        var text = text
        self.bytes.append(UInt8(ascii: "\""))
        text.withUTF8 { utf8 in
            var start = 0
            for index in utf8.indices {
                let byte = utf8[index]
                guard byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") || byte < 0x20 else { continue }
                self.bytes.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[start..<index]))
                self.escape(byte)
                start = index + 1
            }
            self.bytes.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[start...]))
        }
        self.bytes.append(UInt8(ascii: "\""))
    }

    private mutating func escape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "\""): self.raw("\\\"")
        case UInt8(ascii: "\\"): self.raw("\\\\")
        case UInt8(ascii: "\n"): self.raw("\\n")
        case UInt8(ascii: "\r"): self.raw("\\r")
        case UInt8(ascii: "\t"): self.raw("\\t")
        default:
            let hex: [UInt8] = Array("0123456789abcdef".utf8)
            self.raw("\\u00")
            self.bytes.append(hex[Int(byte >> 4)])
            self.bytes.append(hex[Int(byte & 0xF)])
        }
    }
}
