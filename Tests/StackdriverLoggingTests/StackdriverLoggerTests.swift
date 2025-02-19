import NIO
import StackdriverLogging
import XCTest

final class StackdriverLoggingTests: XCTestCase {
    func testStdout() {
        let handler = StackdriverLogHandler(destination: .stdout)
        handler.log(
            level: .error,
            message: "test error log 1",
            metadata: [
                "test-metadata": "hello",
            ],
            source: "StackdriverLoggingTests",
            file: #file,
            function: #function,
            line: #line
        )
        handler.log(
            level: .error,
            message: "test error log 2",
            metadata: nil,
            source: "StackdriverLoggingTests",
            file: #file,
            function: #function,
            line: #line
        )
    }

    func testFile() throws {
        let tmpPath = NSTemporaryDirectory() + "/\(Self.self)+\(UUID()).log"

        let inactiveTP = NIOThreadPool(numberOfThreads: 1)
        let handler = try StackdriverLogHandler(destination: .file(tmpPath), threadPool: inactiveTP)
        handler.log(
            level: .error,
            message: "test error log 1",
            metadata: nil,
            source: "StackdriverLoggingTests",
            file: #file,
            function: #function,
            line: #line
        )

        for (i, line) in try String(contentsOfFile: tmpPath).split(separator: "\n").enumerated() {
            XCTAssertTrue(line.contains("test error log \(i + 1)"))
        }

        handler.log(
            level: .error,
            message: "test error log 2",
            metadata: nil,
            source: "StackdriverLoggingTests",
            file: #file,
            function: #function,
            line: #line
        )

        for (i, line) in try String(contentsOfFile: tmpPath).split(separator: "\n").enumerated() {
            XCTAssertTrue(line.contains("test error log \(i + 1)"))
        }

        try FileManager.default.removeItem(atPath: tmpPath)
    }

    func testSourceLocationLogLevel() throws {
        let tmpPath = NSTemporaryDirectory() + "/\(Self.self)+\(UUID()).log"
        let handler = try StackdriverLogHandler(destination: .file(tmpPath), sourceLocationLogLevel: .error)
        handler.log(level: .warning, message: "Some message", metadata: nil, source: "StackdriverLoggingTests", file: #file, function: #function, line: #line)

        for line in try String(contentsOfFile: tmpPath).split(separator: "\n") {
            XCTAssertFalse(line.contains("sourceLocation"))
        }

        handler.log(level: .error, message: "Some message", metadata: nil, source: "StackdriverLoggingTests", file: #file, function: #function, line: #line)

        for line in try String(contentsOfFile: tmpPath).split(separator: "\n") {
            XCTAssertTrue(line.contains("sourceLocation"))
        }
    }
}
