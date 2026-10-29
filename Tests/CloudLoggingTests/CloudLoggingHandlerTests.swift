import Foundation
import Logging
import Testing

@testable import CloudLogging

// A file rather than a pipe, so large writes don't block waiting for a reader.
final class Capture: Sendable {
    let output: LogOutput
    private let url = FileManager.default.temporaryDirectory.appending(path: "cloud-logging-\(UUID().uuidString).jsonl")
    private let handle: FileHandle

    init() {
        _ = FileManager.default.createFile(atPath: self.url.path, contents: nil)
        self.handle = FileHandle(forWritingAtPath: self.url.path)!
        self.output = LogOutput(fileDescriptor: self.handle.fileDescriptor)
    }

    deinit {
        try? FileManager.default.removeItem(at: self.url)
    }

    func lines() throws -> [[String: Any]] {
        try self.handle.close()
        let data = try Data(contentsOf: self.url)
        return try data.split(separator: UInt8(ascii: "\n")).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }
}

@Test func mergesMetadataInPrecedenceOrder() throws {
    let capture = Capture()
    let provider = Logger.MetadataProvider { ["provider": "p", "shared": "provider"] }
    var logger = Logger(label: "test") { _ in
        CloudLoggingHandler(logLevel: .trace, metadataProvider: provider, output: capture.output)
    }
    logger[metadataKey: "shared"] = "handler"
    logger[metadataKey: "logger"] = "l"

    logger.info("one")
    logger.info("two", metadata: ["shared": "explicit"])
    logger.trace("three")

    let lines = try capture.lines()
    #expect(lines.map { $0["message"] as? String } == ["one", "two", "three"])
    #expect(lines[0]["provider"] as? String == "p")
    #expect(lines[0]["logger"] as? String == "l")
    #expect(lines[0]["shared"] as? String == "handler")
    #expect(lines[1]["shared"] as? String == "explicit")
}

@Test func respectsLogLevel() throws {
    let capture = Capture()
    let logger = Logger(label: "test") { _ in CloudLoggingHandler(logLevel: .warning, output: capture.output) }
    logger.info("dropped")
    logger.warning("kept")
    #expect(try capture.lines().map { $0["message"] as? String } == ["kept"])
}

@Test func passesErrorsThrough() throws {
    let capture = Capture()
    let logger = Logger(label: "test") { _ in CloudLoggingHandler(output: capture.output) }
    logger.error("payment failed", error: Failure())
    let line = try #require(try capture.lines().first)
    #expect((line["error"] as? [String: String])?["type"] == "CloudLoggingTests.Failure")
    #expect(line["@type"] != nil)
}

@Test func concurrentWritesNeverInterleave() async throws {
    let capture = Capture()
    let logger = Logger(label: "test") { _ in CloudLoggingHandler(output: capture.output) }
    let padding = String(repeating: "x", count: 8_000)
    await withTaskGroup { group in
        for task in 0..<8 {
            group.addTask {
                for index in 0..<50 {
                    logger.info("line", metadata: ["task": "\(task)", "index": "\(index)", "padding": "\(padding)"])
                }
            }
        }
    }
    #expect(try capture.lines().count == 400)
}
