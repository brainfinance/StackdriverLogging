import Foundation
import Logging

/// A currently file based only `LogHandler` to log json to GCP Stackdriver using a fluentd config and the GCP logging-assistant.
/// Use the `MetadataValue.stringConvertible` case to log non-string JSON values supported by JSONSerializer like NSNull, Bool, Int, Float/Double, NSNumber, etc.
/// The `MetadataValue.stringConvertible` type will also take care of automatically logging `Date` as an iso8601 timestamp and `Data` as a base64
/// encoded `String`.
///
/// The log entry format matches https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry
public struct StackdriverLogHandler: LogHandler {
    
    public var metadata: Logger.Metadata = .init()
    
    public var logLevel: Logger.Level = .info
    
    private let logFileURL: URL
    
    public init(logFilePath: String) {
        self.logFileURL = URL(fileURLWithPath: logFilePath)
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
            
            var json = StackdriverLogHandler.unpackMetadata(.dictionary(entryMetadata)) as! [String: Any]
            // Checking if this Logger's instance metadata and parameter metadata contains fields reserved by Stackdriver
            // At the moment these are "message", "severity" and "sourceLocation"
            StackdriverLogHandler.checkForReservedMetadataField(metadata: json)
            json["message"] = message.description
            json["severity"] = StackdriverLogHandler.Severity.fromLoggerLevel(level).rawValue
            json["sourceLocation"] = ["file": file, "line": line, "function": function]
            
            do {
                var entry = try JSONSerialization.data(withJSONObject: json, options: [])
                var newLine = UInt8(0x0A)
                entry.append(&newLine, count: 1)
                if !FileManager.default.fileExists(atPath: logFileURL.path) {
                    guard FileManager.default.createFile(atPath: logFileURL.path, contents: entry, attributes: nil) else {
                        print("Failed to create logfile at path: '\(logFileURL.path)'")
                        return
                    }
                } else {
                    do {
                        let fileHandle: Foundation.FileHandle
                        if let currentFileHandle = StackdriverLogHandler.fileHandles[logFileURL] {
                            fileHandle = currentFileHandle
                        } else {
                            fileHandle = try FileHandle(forWritingTo: logFileURL)
                            StackdriverLogHandler.fileHandles[logFileURL] = fileHandle
                        }
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(entry)
                    } catch {
                        print("Failed to create `Foundation.FileHandle` for writing at path: '\(logFileURL.path)'")
                    }
                }
            } catch {
                print("Failed to serialize your log entry metadata to JSON with error: '\(error.localizedDescription)'")
            }
        }
    }
    
    /// `FileHandle` cache for the different filepath logged to by the Stackdriver LogHandler/s
    private static var fileHandles: [URL: Foundation.FileHandle] = [:]
    
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
        switch value {
        case .string(let value):
            return value
        case .stringConvertible(let value):
            if JSONSerialization.isValidJSONObject([value]) {
                return value
            } else if let date = value as? Date {
                return iso8601DateFormatter.string(from: date)
            } else if let data = value as? Data {
                return data.base64EncodedString()
            } else {
                return value.description
            }
        case .array(let value):
            return value.map { StackdriverLogHandler.unpackMetadata($0) }
        case .dictionary(let value):
            return value.mapValues { StackdriverLogHandler.unpackMetadata($0) }
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

// public types
extension StackdriverLogHandler {
    /// A reserved Stackdriver log entry metadata property, see https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#logentryoperation
    public struct LogEntryOperation {
        public var id: String?
        public var producer: String?
        public var first: Bool?
        public var last: Bool?
        
        public init(id: String?, producer: String?, first: Bool?, last: Bool?) {
            self.id = id
            self.producer = producer
            self.first = first
            self.last = last
        }
    }
    
    /// A reserved Stackdriver log entry metadata property, https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#httprequest
    public struct HTTPRequest {
        public var requestMethod: String?
        public var requestUrl: String?
        public var requestSize: String?
        public var status: Int?
        public var responseSize: String?
        public var userAgent: String?
        public var remoteIp: String?
        public var serverIp: String?
        public var referer: String?
        public var latency: String?
        public var cacheLookup: Bool?
        public var cacheHit: Bool?
        public var cacheValidatedWithOriginServer: Bool?
        public var cacheFillBytes: String?
        public var `protocol`: String?
        
        public init(requestMethod: String?,
                    requestUrl: String?,
                    requestSize: String?,
                    status: Int?,
                    responseSize: String?,
                    userAgent: String?,
                    remoteIp: String?,
                    serverIp: String?,
                    referer: String?,
                    latency: String?,
                    cacheLookup: Bool?,
                    cacheHit: Bool?,
                    cacheValidatedWithOriginServer: Bool?,
                    cacheFillBytes: String?,
                    protocol: String?) {
            self.requestMethod = requestMethod
            self.requestUrl = requestUrl
            self.requestSize = requestSize
            self.status = status
            self.responseSize = responseSize
            self.userAgent = userAgent
            self.remoteIp = remoteIp
            self.serverIp = serverIp
            self.referer = referer
            self.latency = latency
            self.cacheLookup = cacheLookup
            self.cacheHit = cacheHit
            self.cacheValidatedWithOriginServer = cacheValidatedWithOriginServer
            self.cacheFillBytes = cacheFillBytes
            self.protocol = `protocol`
        }
    }
}

extension Logger {
    public mutating func setLogEntryOperationMetadata(_ logEntryOperation: StackdriverLogHandler.LogEntryOperation) {
        var metadataValue: Logger.Metadata = [:]
        metadataValue["id"] = .optionalString(logEntryOperation.id)
        metadataValue["producer"] = .optionalString(logEntryOperation.producer)
        metadataValue["first"] = .optionalStringConvertible(logEntryOperation.first)
        metadataValue["last"] = .optionalStringConvertible(logEntryOperation.last)
        self[metadataKey: "operation"] = .dictionary(metadataValue)
    }
    public mutating func setHTTPRequestMetadata(_ httpRequest: StackdriverLogHandler.HTTPRequest) {
        var metadataValue: Logger.Metadata = [:]
        metadataValue["requestMethod"] = .optionalString(httpRequest.requestMethod)
        metadataValue["requestUrl"] = .optionalString(httpRequest.requestUrl)
        metadataValue["requestSize"] = .optionalString(httpRequest.requestSize)
        metadataValue["status"] = .optionalStringConvertible(httpRequest.status)
        metadataValue["responseSize"] = .optionalString(httpRequest.requestSize)
        metadataValue["userAgent"] = .optionalString(httpRequest.userAgent)
        metadataValue["remoteIp"] = .optionalString(httpRequest.remoteIp)
        metadataValue["serverIp"] = .optionalString(httpRequest.serverIp)
        metadataValue["referer"] = .optionalString(httpRequest.referer)
        metadataValue["latency"] = .optionalString(httpRequest.latency)
        metadataValue["cacheLookup"] = .optionalStringConvertible(httpRequest.cacheLookup)
        metadataValue["cacheHit"] = .optionalStringConvertible(httpRequest.cacheHit)
        metadataValue["cacheValidatedWithOriginServer"] = .optionalStringConvertible(httpRequest.cacheValidatedWithOriginServer)
        metadataValue["cacheFillBytes"] = .optionalString(httpRequest.cacheFillBytes)
        metadataValue["protocol"] = .optionalString(httpRequest.protocol)
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

// internal types
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
