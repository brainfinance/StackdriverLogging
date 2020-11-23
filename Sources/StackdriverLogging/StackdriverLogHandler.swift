import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers

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
    public enum Destination: CustomStringConvertible {
        case file(_ filepath: String)
        case stdout
        
        public var description: String {
            switch self {
            case .stdout:
                return "standard output"
            case .file(let filePath):
                return URL(fileURLWithPath: filePath).description
            }
        }
    }
    
    public var metadata: Logger.Metadata = .init()
    
    public var logLevel: Logger.Level = .info
    
    private let destination: Destination
    
    private let fileHandle: NIOFileHandle
    
    private let fileIO: NonBlockingFileIO
    
    private let processingEventLoopGroup: EventLoopGroup
    
    fileprivate init(destination: Destination, fileHandle: NIOFileHandle, fileIO: NonBlockingFileIO, processingEventLoopGroup: EventLoopGroup) {
        self.destination = destination
        self.fileHandle = fileHandle
        self.fileIO = fileIO
        self.processingEventLoopGroup = processingEventLoopGroup
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
        let eventLoop = processingEventLoopGroup.next()
        eventLoop.execute {
            // JSONSerialization and its internal JSONWriter calls seem to leak significant memory, especially when
            // called recursively or in loops. Wrapping the calls in an autoreleasepool fixes the problems entirely on Darwin.
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
                assert(json["timestamp"] == nil, "'timestamp' is a metadata field reserved by Stackdriver, your custom 'timestamp' metadata value will be overriden in production")
                
                json["message"] = message.description
                json["severity"] = Severity.fromLoggerLevel(level).rawValue
                json["sourceLocation"] = ["file": Self.conciseSourcePath(file), "line": line, "function": function]
                json["timestamp"] = Self.iso8601DateFormatter.string(from: Date())
                
                do {
                    let entry = try JSONSerialization.data(withJSONObject: json, options: [])
                    
                    var buffer = ByteBufferAllocator().buffer(capacity: entry.count + 1)
                    buffer.writeBytes(entry)
                    buffer.writeInteger(0x0A, as: UInt8.self) // Appends a new line at the end of the entry
                    
                    self.fileIO.write(fileHandle: self.fileHandle, buffer: buffer, eventLoop: eventLoop)
                        .whenFailure { error in
                            print("Failed to write logfile entry to '\(self.destination)' with error: '\(error.localizedDescription)'")
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

extension StackdriverLogHandler {
    /// A factory enum used to create new instances of `StackdriverLogHandler`.
    /// You must first prepare it by calling the `prepare(_:_:)` function. You must also shutdown the internal dependencies
    /// created by this factory and used internally by the `StackdriverLogHandler`s by calling the `syncShutdownGracefully`.
    /// This is commonly done in a defer statement after preparing the facotry using the `prepare(_:_:)
    public enum Factory {
        
        public enum State {
            case initial
            case running
            case shutdown
        }
        
        public private(set) static var state = State.initial
        private static let lock = Lock()
        private static var eventLoopGroup: MultiThreadedEventLoopGroup?
        private static var threadPool: NIOThreadPool?
        
        private static var logger: StackdriverLogHandler!
        
        /// Shuts the `StackdriverLogHandler.Factory` down which will close and shutdown the `NIOThreadPool` and the
        /// `MultiThreadedEventLoopGroup` used internally by the `StackdriverLogHandler`s to write log entries.
        ///
        /// A good practice is to call this in a defer statement after preparing the factory using the `prepare(_:_:)` function.
        public static func syncShutdownGracefully() throws {
            defer {
                self.lock.withLockVoid {
                    self.state = .shutdown
                }
            }
            try self.threadPool?.syncShutdownGracefully()
            try self.eventLoopGroup?.syncShutdownGracefully()
        }
        
        /// Prepares the factory's internal so that new `LogHandler`s can be made using its `make` function. This will create
        /// certain internal dependencies that must be shutdown before your application exits using the `syncShutdownGracefully` function.
        ///
        /// - Parameters:
        ///   - destination: The destination at which to send the logs to such as the standard output or a file.
        ///   - numberOfThreads: The number of threads that will be used to process and write new log entries.
        public static func prepare(
            for destination: StackdriverLogHandler.Destination,
            numberOfThreads: Int = NonBlockingFileIO.defaultThreadPoolSize
        ) throws {
            self.logger = try lock.withLock {
                assert(state == .initial, "`StackdriverLogHandler.Factory.prepare` should only be called once.")
                defer {
                    self.state = .running
                }

                let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)
                self.eventLoopGroup = eventLoopGroup
                
                let threadPool = NIOThreadPool(numberOfThreads: numberOfThreads)
                threadPool.start()
                self.threadPool = threadPool
                
                let fileIO = NonBlockingFileIO(threadPool: threadPool)
                
                let fileHandle: NIOFileHandle
                switch destination {
                case .stdout:
                    fileHandle = NIOFileHandle(descriptor: FileHandle.standardOutput.fileDescriptor)
                case .file(let filepath):
                    fileHandle = try NIOFileHandle(
                        path: filepath,
                        mode: .write,
                        flags: .posix(flags: O_APPEND | O_CREAT, mode: S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH)
                    )
                }
                
                return StackdriverLogHandler(
                    destination: destination,
                    fileHandle: fileHandle,
                    fileIO: fileIO,
                    processingEventLoopGroup: eventLoopGroup
                )
            }
        }
        
        /// Creates a new `StackdriverLogHandler` instance.
        public static func make() -> StackdriverLogHandler {
            assert(state == .running, "You must prepare the `StackdriverLogHandler.Factory` with the `prepare` method before creating new loggers.")
            return logger
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
