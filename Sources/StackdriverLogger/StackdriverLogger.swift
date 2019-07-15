import Foundation
import Logging

public struct StackDriverLogHandler: LogHandler {
    
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
            var entryMetadata: Logger.Metadata?
            if let parameterMetadata = metadata, !parameterMetadata.isEmpty {
                entryMetadata = self.metadata.merging(parameterMetadata) { $1 }
            } else if !self.metadata.isEmpty {
                entryMetadata = self.metadata
            }
            
            var json: [String: Any] = [
                "message": message.description,
            ]
            if let entryMetadata = entryMetadata {
                json["metadata"] = StackDriverLogHandler.unpackMetadata(.dictionary(entryMetadata))
            }
            do {
                var entry = try JSONSerialization.data(withJSONObject: json, options: [])
                var newLine = UInt8(0x0A)
                entry.append(&newLine, count: 1)
                if !FileManager.default.fileExists(atPath: logFileURL.path) {
                    guard FileManager.default.createFile(atPath: logFileURL.path, contents: entry, attributes: nil) else {
                        print(Error.logFileCreationFailed(path: logFileURL.path).localizedDescription)
                        return
                    }
                } else {
                    do {
                        let fileHandle: Foundation.FileHandle
                        if let currentFileHandle = StackDriverLogHandler.fileHandles[logFileURL] {
                            fileHandle = currentFileHandle
                        } else {
                            fileHandle = try FileHandle(forWritingTo: logFileURL)
                            StackDriverLogHandler.fileHandles[logFileURL] = fileHandle
                        }
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(entry)
                    } catch {
                        print("Failed to create FileHandle for writting at: \"\(logFileURL.path)\"")
                        return
                    }
                }
            } catch {
                print(error)
            }
        }
    }
    
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
            return value.map { StackDriverLogHandler.unpackMetadata($0) }
        case .dictionary(let value):
            return value.mapValues { StackDriverLogHandler.unpackMetadata($0) }
        }
    }
    
}

// static properties
extension StackDriverLogHandler {
    /// `FileHandle` cache for the different filepath logged to by the Stackdriver LogHandler/s
    private static var fileHandles: [URL: Foundation.FileHandle] = [:]
    
    /// iso8601 `DateFormatter` wich is the standard timestamp format in Stackdriver
    private static let iso8601DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()
}
