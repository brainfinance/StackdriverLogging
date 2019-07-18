import Foundation
import Logging
import NIO

/// A `LogHandler` to log json to GCP Stackdriver using a fluentd config and the GCP logging-assistant.
/// Use the `MetadataValue.stringConvertible` case to log non-string JSON values supported by JSONSerializer like NSNull, Bool, Int, Float/Double, NSNumber, etc.
/// The `MetadataValue.stringConvertible` type will also take care of automatically logging `Date` as an iso8601 timestamp and `Data` as a base64
/// encoded `String`.
///
/// The log entry format matches https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry
public struct StackdriverLogHandler: LogHandler {
    
    public var metadata: Logger.Metadata = .init()
    
    public var logLevel: Logger.Level = .info
    
    private let logFileURL: URL
    
    /// Instantiate the Logger as well as creating an associated `NIO.FileHandle` to your logfile (creating the logfile if it does not exist already)
    /// Throws an exception if the `NIO.FileHandle` cannot be created.
    public init(logFilePath: String) throws {
        let logFileURL = URL(fileURLWithPath: logFilePath)
        try Self.readWriteLock.withWriterLock {
            if let existingFileHandle = Self.fileHandles[logFileURL] {
                if !FileManager.default.fileExists(atPath: logFileURL.path) {
                    do {
                        try existingFileHandle.close()
                    } catch {
                        print("Failed to close fileHandle for deleted file with error: '\(error.localizedDescription)'")
                    }
                    Self.fileHandles[logFileURL] = try Self.logfileHandleForPath(logFileURL.path)
                }
            } else {
                Self.fileHandles[logFileURL] = try Self.logfileHandleForPath(logFileURL.path)
            }
        }
        self.logFileURL = logFileURL
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
        let eventLoop = Self.processingEventLoopGroup.next()
        eventLoop.execute {
            // JSONSerialization and its internal JSONWriter calls seem to leak significant memory, especially when
            // called recursively or in loops. Wrapping the calls in an autoreleasepool fixes the problems entirely.
            // see: https://bugs.swift.org/browse/SR-5501
            autoreleasepool {
                let entryMetadata: Logger.Metadata
                if let parameterMetadata = metadata {
                    entryMetadata = self.metadata.merging(parameterMetadata) { $1 }
                } else {
                    entryMetadata = self.metadata
                }
                
                var json = Self.unpackMetadata(.dictionary(entryMetadata)) as! [String: Any]
                // Checking if this Logger's instance metadata and parameter metadata contains fields reserved by Stackdriver
                // At the moment these are "message", "severity" and "sourceLocation"
                Self.checkForReservedMetadataField(metadata: json)
                json["message"] = message.description
                json["severity"] = Severity.fromLoggerLevel(level).rawValue
                json["sourceLocation"] = ["file": file, "line": line, "function": function]
                
                do {
                    var entry = try JSONSerialization.data(withJSONObject: json, options: [])
                    var newLine = UInt8(0x0A)
                    entry.append(&newLine, count: 1)
                    
                    var byteBuffer = ByteBufferAllocator().buffer(capacity: entry.count)
                    byteBuffer.writeBytes(entry)
                    
                    var fileHandle: NIOFileHandle!
                    Self.readWriteLock.withReaderLock {
                        fileHandle = Self.fileHandles[self.logFileURL]
                    }
                    
                    Self.nonBlockingFileIO.write(fileHandle: fileHandle, buffer: byteBuffer, eventLoop: eventLoop)
                        .whenFailure { error in
                            print("Failed to write logfile entry at '\(self.logFileURL.path)' with error: '\(error.localizedDescription)'")
                        }
                } catch {
                    print("Failed to serialize your log entry metadata to JSON with error: '\(error.localizedDescription)'")
                }
            }
        }
    }
    
    private static func logfileHandleForPath(_ path: String) throws -> NIOFileHandle {
        return try NIOFileHandle(path: path,
                                 mode: .write,
                                 flags: .posix(flags: O_APPEND | O_CREAT, mode: S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH))
    }
    
    /// Used to write log entries to file asynchronously
    private static let nonBlockingFileIO: NonBlockingFileIO = {
        let threadPool = NIOThreadPool(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
        threadPool.start()
        return NonBlockingFileIO(threadPool: threadPool)
    }()
    
    /// Used to encode unpack the metadata and encore the data asynchronously. The callbacks of the write operations are also executed onto these `EventLoop`s (notably when printing write operation errors to the console)
    private static let processingEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
    
    /// Used to create the `NIOFileHandle`s atomically.
    private static let readWriteLock = ReadWriteLock()
    
    /// `NIOFileHandle` cache for the different filepath logged to by the Stackdriver LogHandler/s
    private static var fileHandles: [URL: NIOFileHandle] = [:]
    
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
    
    /// Warn in case the parameter `metadata` contains fields reserved by Stackdriver. At the moment these are: "message", "severity" and "sourceLocation".
    private static func checkForReservedMetadataField(metadata: [String: Any]) {
        assert(metadata["message"] == nil, "'message' is a metadata field reserved by Stackdriver, your custom 'message' metadata value will be overriden in production")
        if metadata["message"] != nil {
            print("'message' is a metadata field reserved by Stackdriver, your custom 'message' metadata value will be overriden by the log's message")
        }
        
        assert(metadata["severity"] == nil, "'severity' is a metadata field reserved by Stackdriver, your custom 'severity' metadata value will be overriden in production")
        if metadata["severity"] != nil {
            print("'severity' is a metadata field reserved by Stackdriver, your custom 'severity' metadata value will be overriden by the log's severity")
        }
        
        assert(metadata["sourceLocation"] == nil, "'sourceLocation' is a metadata field reserved by Stackdriver, your custom 'sourceLocation' metadata value will be overriden in production")
        if metadata["sourceLocation"] != nil {
            print("'sourceLocation' is a metadata field reserved by Stackdriver, your custom 'sourceLocation' metadata value will be overriden by the log's sourceLocation")
        }
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
