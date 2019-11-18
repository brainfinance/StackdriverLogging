import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers

/// A global configuration for the `StackdriverLogHandler`s created by the `StackdriverLogHandlerFactory`.
public struct StackdriverLoggingConfig: Codable {
    
    /// The filePath of your Stackdriver logging agent structured JSON logfile.
    public var logFilePath: String
    
    /// The default Logger.Level of your factory's loggers.
    public var logLevel: Logger.Level
    
    /// Controls if a timestamp is attached to log entries. The recommended value is `false` for production environments
    /// in order to defer the responsability of attaching timestamps to log entries to Stackdriver itself.
    public var logTimestamps: Bool = false
    
    public init(logFilePath: String, defaultLogLevel logLevel: Logger.Level, logTimestamps: Bool = false) {
        self.logFilePath = logFilePath
        self.logLevel = logLevel
        self.logTimestamps = logTimestamps
    }
    
}

/// A factory enum to create new instances of `StackdriverLogHandler`.
/// You must first prepare it by calling the `prepare:` function with a `StackdriverLoggingConfig`
public enum StackdriverLogHandlerFactory {
    public typealias Config = StackdriverLoggingConfig
    
    private static var initialized = false
    private static let lock = Lock()
    
    private static var logger: StackdriverLogHandler!
    
    /// Prepares the factory's internals to be able to create `LogHandlers`s using the `make` function.
    ///
    /// ** Must be called before being able to instantiate new `StackdriverLogHandler`s with the `make`
    ///  factory function.
    public static func prepare(with config: Config) throws {
        self.logger = try lock.withLock {
            assert(initialized == false, "`StackdriverLogHandlerFactory` `prepare` should only be called once.")
            defer {
                initialized = true
            }
            
            let logFileURL = URL(fileURLWithPath: config.logFilePath)
            let fileHandle = try NIOFileHandle(path: config.logFilePath,
                                               mode: .write,
                                               flags: .posix(flags: O_APPEND | O_CREAT, mode: S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH))
            let threadPool = NIOThreadPool(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
            threadPool.start()
            let fileIO = NonBlockingFileIO(threadPool: threadPool)
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
            
            var logger = StackdriverLogHandler(logFileURL: logFileURL,
                                               fileHandle: fileHandle,
                                               fileIO: fileIO,
                                               processingEventLoopGroup: eventLoopGroup,
                                               logTimestamps: config.logTimestamps)
            logger.logLevel = config.logLevel
            return logger
        }
    }
    
    /// Creates a new `StackdriverLogHandler` instance.
    public static func make() -> StackdriverLogHandler {
        assert(initialized == true, "You must prepare the `StackdriverLogHandlerFactory` with the `prepare` method before creating new loggers.")
        return logger
    }
    
}

/// A `LogHandler` to log json to GCP Stackdriver using a fluentd config and the GCP logging-assistant.
/// Use the `MetadataValue.stringConvertible` case to log non-string JSON values supported by JSONSerializer like NSNull, Bool, Int, Float/Double, NSNumber, etc.
/// The `MetadataValue.stringConvertible` type will also take care of automatically logging `Date` as an iso8601 timestamp and `Data` as a base64
/// encoded `String`.
///
/// The log entry format matches https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry
///
/// ** Use the `StackdriverLogHandlerFactory` to instantiate new `StackdriverLogHandler` instances.
public struct StackdriverLogHandler: LogHandler {
    public typealias Factory = StackdriverLogHandlerFactory
    
    public var metadata: Logger.Metadata = .init()
    
    public var logLevel: Logger.Level = .info
    
    private let logFileURL: URL
    
    private let fileHandle: NIOFileHandle
    
    private let fileIO: NonBlockingFileIO
    
    private let processingEventLoopGroup: EventLoopGroup
    
    private let logTimestamps: Bool
    
    fileprivate init(logFileURL: URL, fileHandle: NIOFileHandle, fileIO: NonBlockingFileIO, processingEventLoopGroup: EventLoopGroup, logTimestamps: Bool) {
        self.logFileURL = logFileURL
        self.fileHandle = fileHandle
        self.fileIO = fileIO
        self.processingEventLoopGroup = processingEventLoopGroup
        self.logTimestamps = logTimestamps
    }
    
    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get {
            return metadata[key]
        }
        set(newValue) {
            metadata[key] = newValue
        }
    }
    
    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt) {
        let eventLoop = processingEventLoopGroup.next()
        eventLoop.execute {
            // JSONSerialization and its internal JSONWriter calls seem to leak significant memory, especially when
            // called recursively or in loops. Wrapping the calls in an autoreleasepool fixes the problems entirely on Darwing.
            // see: https://bugs.swift.org/browse/SR-5501
            withAutoReleasePool {
                let entryMetadata: Logger.Metadata
                if let parameterMetadata = metadata {
                    entryMetadata = self.metadata.merging(parameterMetadata) { $1 }
                } else {
                    entryMetadata = self.metadata
                }
                
                var json = Self.unpackMetadata(.dictionary(entryMetadata)) as! [String: Any]
                assert(json["message"] == nil, "'message' is a metadata field reserved by Stackdriver, your custom 'message' metadata value will be overriden in production")
                assert(json["severity"] == nil, "'severity' is a metadata field reserved by Stackdriver, your custom 'severity' metadata value will be overriden in production")
                assert(json["sourceLocation"] == nil, "'sourceLocation' is a metadata field reserved by Stackdriver, your custom 'sourceLocation' metadata value will be overriden in production")
                
                json["message"] = message.description
                json["severity"] = Severity.fromLoggerLevel(level).rawValue
                json["sourceLocation"] = ["file": Self.conciseSourcePath(file), "line": line, "function": function]
                if self.logTimestamps {
                    json["timestamp"] = Self.iso8601DateFormatter.string(from: Date())
                }
                
                do {
                    let entry = try JSONSerialization.data(withJSONObject: json, options: [])
                    
                    var buffer = ByteBufferAllocator().buffer(capacity: entry.count + 1)
                    buffer.writeBytes(entry)
                    buffer.writeInteger(0x0A, as: UInt8.self) // Appends a new line at the end of the entry
                    
                    self.fileIO.write(fileHandle: self.fileHandle, buffer: buffer, eventLoop: eventLoop)
                        .whenFailure { error in
                            print("Failed to write logfile entry at '\(self.logFileURL.path)' with error: '\(error.localizedDescription)'")
                        }
                } catch {
                    print("Failed to serialize your log entry metadata to JSON with error: '\(error.localizedDescription)'")
                }
            }
        }
    }
    
    /// ISO 8601 `DateFormatter` which is the accepted format for timestamps in Stackdriver
    private static let iso8601DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()
    
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
                                                status: Int?,
                                                responseSize: String? = nil,
                                                userAgent: String?,
                                                remoteIp: String? = nil,
                                                serverIp: String? = nil,
                                                referer: String?,
                                                latency: String? = nil,
                                                cacheLookup: Bool? = nil,
                                                cacheHit: Bool? = nil,
                                                cacheValidatedWithOriginServer: Bool? = nil,
                                                cacheFillBytes: String? = nil,
                                                protocol: String?) {
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
