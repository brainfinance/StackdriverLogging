import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import SystemPackage

/// `LogHandler` to log JSON to GCP Stackdriver using a fluentd config and the GCP logging-assistant.
/// Use the `MetadataValue.stringConvertible` case to log non-string JSON values supported by JSONSerializer such as NSNull, Bool, Int, Float/Double, NSNumber, etc.
/// The `MetadataValue.stringConvertible` type will also take care of automatically logging `Date` as an iso8601 timestamp and `Data` as a base64
/// encoded `String`.
///
/// The log entry format matches https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry
///
/// ** Use the `StackdriverLogHandler.Factory` to instantiate new `StackdriverLogHandler` instances.
public struct StackdriverLogHandler: LogHandler {
    /// A `StackdriverLogHandler` output destination, can be either the standard output or a file.
    public struct Destination: CustomStringConvertible {
        internal enum Kind {
            case file(_ filepath: String)
            case stdout
        }

        internal var kind: Kind
        internal var fd: SystemPackage.FileDescriptor

        public static func file(_ filepath: String) throws -> Destination {
            return .init(
                kind: .file(filepath),
                fd: try SystemPackage.FileDescriptor.open(
                    FilePath(filepath),
                    .writeOnly,
                    options: [.append, .create],
                    permissions: FilePermissions(rawValue: 0o644)
                )
            )
        }

        public static var stdout: Destination {
            return .init(
                kind: .stdout,
                fd: .standardOutput
            )
        }

        public var description: String {
            switch kind {
            case .stdout:
                return "standard output"
            case .file(let filePath):
                return URL(fileURLWithPath: filePath).description
            }
        }
    }
    
    public var metadata: Logger.Metadata = .init()
    public var metadataProvider: Logger.MetadataProvider? = nil
    
    public var logLevel: Logger.Level = .info
    
    private var destination: Destination
    private var threadPool: NIOThreadPool

    public init(destination: Destination, threadPool: NIOThreadPool = .singleton) throws {
        self.destination = destination
        self.threadPool = threadPool
    }
    
    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get {
            return metadata[key]
        }
        set(newValue) {
            metadata[key] = newValue
        }
    }
    
    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        let providerMetadata = self.metadataProvider?.get()

        // run in threadpool or immediately (when threadpool is inactive)
        threadPool.submit { _ in
            // JSONSerialization and its internal JSONWriter calls seem to leak significant memory, especially when
            // called recursively or in loops. Wrapping the calls in an autoreleasepool fixes the problems entirely on Darwin.
            // see: https://bugs.swift.org/browse/SR-5501
            withAutoReleasePool {
                var entryMetadata: Logger.Metadata = [:]
                if let providerMetadata = providerMetadata {
                    entryMetadata.merge(providerMetadata) { $1 }
                }
                entryMetadata.merge(self.metadata) { $1 }
                if let metadata = metadata {
                    entryMetadata.merge(metadata) { $1 }
                }
                
                var json = Self.unpackMetadata(.dictionary(entryMetadata)) as! [String: Any]
                assert(json["message"] == nil, "'message' is a metadata field reserved by Stackdriver, your custom 'message' metadata value will be overriden in production")
                assert(json["severity"] == nil, "'severity' is a metadata field reserved by Stackdriver, your custom 'severity' metadata value will be overriden in production")
                assert(json["sourceLocation"] == nil, "'sourceLocation' is a metadata field reserved by Stackdriver, your custom 'sourceLocation' metadata value will be overriden in production")
                assert(json["timestamp"] == nil, "'timestamp' is a metadata field reserved by Stackdriver, your custom 'timestamp' metadata value will be overriden in production")
                
                json["message"] = message.description
                json["severity"] = Severity.fromLoggerLevel(level).rawValue
                json["sourceLocation"] = ["file": Self.conciseSourcePath(file), "line": line, "function": function]
                json["timestamp"] = Self.iso8601DateFormatter.string(from: Date())
                
                let entry: Data
                do {
                    var _entry = try JSONSerialization.data(withJSONObject: json, options: [])
                    _entry.append(0x0A) // Appends a new line at the end of the entry
                    entry = _entry
                } catch {
                    print("Failed to serialize your log entry metadata to JSON with error: '\(error.localizedDescription)'")
                    return
                }

                do {
                    try self.destination.fd.writeAll(entry)
                } catch {
                    print("Failed to write logfile entry to '\(self.destination)' with error: '\(error.localizedDescription)'")
                }
            }
        }
    }
    
    /// ISO 8601 `DateFormatter` which is the accepted format for timestamps in Stackdriver
    private static var iso8601DateFormatter: DateFormatter {
        let key = "StackdriverLogHandler_iso8601DateFormatter"
        let threadLocal = Thread.current.threadDictionary
        if let value = threadLocal[key] {
            return value as! DateFormatter
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"

        threadLocal[key] = formatter
        return formatter
    }
    
    private static func unpackMetadata(_ value: Logger.MetadataValue) -> Any {
        /// Based on the core-foundation implementation of `JSONSerialization.isValidObject`, but optimized to reduce the amount of comparisons done per validation.
        /// https://github.com/apple/swift-corelibs-foundation/blob/9e505a94e1749d329563dac6f65a32f38126f9c5/Foundation/JSONSerialization.swift#L52
        func isValidJSONValue(_ value: CustomStringConvertible) -> Bool {
            if value is Int || value is Bool || value is NSNull ||
                (value as? Double)?.isFinite ?? false ||
                (value as? Float)?.isFinite ?? false ||
                (value as? Decimal)?.isFinite ?? false ||
                value is UInt ||
                value is Int8 || value is Int16 || value is Int32 || value is Int64 ||
                value is UInt8 || value is UInt16 || value is UInt32 || value is UInt64 ||
                value is String {
                return true
            }
            
            // Using the official `isValidJSONObject` call for NSNumber since `JSONSerialization.isValidJSONObject` uses internal/private functions to validate them...
            if let number = value as? NSNumber {
                return JSONSerialization.isValidJSONObject([number])
            }
            
            return false
        }
        
        switch value {
        case .string(let value):
            return value
        case .stringConvertible(let value):
            if isValidJSONValue(value) {
                return value
            } else if let date = value as? Date {
                return iso8601DateFormatter.string(from: date)
            } else if let data = value as? Data {
                return data.base64EncodedString()
            } else {
                return value.description
            }
        case .array(let value):
            return value.map { Self.unpackMetadata($0) }
        case .dictionary(let value):
            return value.mapValues { Self.unpackMetadata($0) }
        }
    }
    
    private static func conciseSourcePath(_ path: String) -> String {
        return path.split(separator: "/")
            .split(separator: "Sources")
            .last?
            .joined(separator: "/") ?? path
    }
    
}

// Internal Stackdriver and related mapping from `Logger.Level`
extension StackdriverLogHandler {
    /// The Stackdriver internal `Severity` levels
    fileprivate enum Severity: String {
        /// (0) The log entry has no assigned severity level.
        case `default` = "DEFAULT"
        
        /// (100) Debug or trace information.
        case debug = "DEBUG"
        
        /// (200) Routine information, such as ongoing status or performance.
        case info = "INFO"
        
        /// (300) Normal but significant events, such as start up, shut down, or a configuration change.
        case notice = "NOTICE"
        
        /// (400) Warning events might cause problems.
        case warning = "WARNING"
        
        /// (500) Error events are likely to cause problems.
        case error = "ERROR"
        
        /// (600) Critical events cause more severe problems or outages.
        case critical = "CRITICAL"
        
        /// (700) A person must take an action immediately.
        case alert = "ALERT"
        
        /// (800) One or more systems are unusable.
        case emergency = "EMERGENCY"
        
        static func fromLoggerLevel(_ level: Logger.Level) -> Self {
            switch level {
            case .trace, .debug:
                return .debug
            case .info:
                return .info
            case .notice:
                return .notice
            case .warning:
                return .warning
            case .error:
                return .error
            case .critical:
                return .critical
            }
        }
    }
}

// Stackdriver related metadata helpers
extension Logger {
    /// Set the metadata for a Stackdriver formatted "LogEntryOperation", i.e used to give a unique tag to all the log entries related to some, potentially long running, operation
    /// https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#logentryoperation
    public mutating func setLogEntryOperationMetadata(id: String, producer: String?, first: Bool? = nil, last: Bool? = nil) {
        var metadataValue: Logger.Metadata = [:]
        metadataValue["id"] = .optionalString(id)
        metadataValue["producer"] = .optionalString(producer)
        metadataValue["first"] = .optionalStringConvertible(first)
        metadataValue["last"] = .optionalStringConvertible(last)
        self[metadataKey: "operation"] = .dictionary(metadataValue)
    }
    /// Set the metadata for a Stackdriver formatted "HTTPRequest", i.e to associated a particular HTTPRequest with your log entries.
    /// https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#httprequest
    public mutating func setHTTPRequestMetadata(requestMethod: String?,
                                                requestUrl: String?,
                                                requestSize: String? = nil,
                                                status: Int? = nil,
                                                responseSize: String? = nil,
                                                userAgent: String? = nil,
                                                remoteIp: String? = nil,
                                                serverIp: String? = nil,
                                                referer: String? = nil,
                                                latency: String? = nil,
                                                cacheLookup: Bool? = nil,
                                                cacheHit: Bool? = nil,
                                                cacheValidatedWithOriginServer: Bool? = nil,
                                                cacheFillBytes: String? = nil,
                                                protocol: String? = nil) {
        var metadataValue: Logger.Metadata = [:]
        metadataValue["requestMethod"] = .optionalString(requestMethod)
        metadataValue["requestUrl"] = .optionalString(requestUrl)
        metadataValue["requestSize"] = .optionalString(requestSize)
        metadataValue["status"] = .optionalStringConvertible(status)
        metadataValue["responseSize"] = .optionalString(requestSize)
        metadataValue["userAgent"] = .optionalString(userAgent)
        metadataValue["remoteIp"] = .optionalString(remoteIp)
        metadataValue["serverIp"] = .optionalString(serverIp)
        metadataValue["referer"] = .optionalString(referer)
        metadataValue["latency"] = .optionalString(latency)
        metadataValue["cacheLookup"] = .optionalStringConvertible(cacheLookup)
        metadataValue["cacheHit"] = .optionalStringConvertible(cacheHit)
        metadataValue["cacheValidatedWithOriginServer"] = .optionalStringConvertible(cacheValidatedWithOriginServer)
        metadataValue["cacheFillBytes"] = .optionalString(cacheFillBytes)
        metadataValue["protocol"] = .optionalString(`protocol`)
        self[metadataKey: "httpRequest"] = .dictionary(metadataValue)
    }
}

extension Logger.MetadataValue {
    fileprivate static func optionalString(_ value: String?) -> Logger.MetadataValue? {
        guard let value = value else {
            return nil
        }
        return .string(value)
    }
    fileprivate static func optionalStringConvertible(_ value: CustomStringConvertible?) -> Logger.MetadataValue? {
        guard let value = value else {
            return nil
        }
        return .stringConvertible(value)
    }
}

private func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
    #if os(Linux)
    return try execute()
    #else
    return try autoreleasepool {
        try execute()
    }
    #endif
}
