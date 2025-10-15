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
        let tmpPath = NSTemporaryDirectory() + "\(Self.self)+\(UUID()).log"

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

        var foundLines = false
        for (i, line) in try String(contentsOfFile: tmpPath).split(separator: "\n").enumerated() {
            XCTAssertTrue(line.contains("test error log \(i + 1)"))
            foundLines = true
        }
        XCTAssertTrue(foundLines)

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
        try inactiveTP.syncShutdownGracefully()
    }

    func testSourceLocationLogLevel() throws {
        let inactiveTP = NIOThreadPool(numberOfThreads: 1)
        let tmpPath = NSTemporaryDirectory() + "\(Self.self)+\(UUID()).log"
        let handler = try StackdriverLogHandler(destination: .file(tmpPath), threadPool: inactiveTP, sourceLocationLogLevel: .error)
        handler.log(level: .warning, message: "Some message", metadata: nil, source: "StackdriverLoggingTests", file: #file, function: #function, line: #line)

        var foundLines = false
        for line in try String(contentsOfFile: tmpPath).split(separator: "\n") {
            XCTAssertFalse(line.contains("sourceLocation"))
            foundLines = true
        }
        XCTAssertTrue(foundLines)

        handler.log(level: .error, message: "Some message", metadata: nil, source: "StackdriverLoggingTests", file: #file, function: #function, line: #line)

        foundLines = false
        for (index, line) in try String(contentsOfFile: tmpPath).split(separator: "\n").enumerated() {
            // Ignore the first line as that's the warning location
            if index > 0 {
                XCTAssertTrue(line.contains("sourceLocation"))
                foundLines = true
            }
        }
        XCTAssertTrue(foundLines)
        try inactiveTP.syncShutdownGracefully()
    }
    
    func testErrorLogReportsTypeAtErrorLevel() throws {
        let tmpPath = NSTemporaryDirectory() + "\(Self.self)+\(UUID()).log"
        let tp = NIOThreadPool(numberOfThreads: 1)
        
        let handler = try StackdriverLogHandler(destination: .file(tmpPath), threadPool: tp)
        handler.log(
            level: .error,
            message: "test error log 1",
            metadata: nil,
            source: "StackdriverLoggingTests",
            file: #file,
            function: #function,
            line: #line
        )
        
        handler.log(
            level: .critical,
            message: "test error log 1",
            metadata: nil,
            source: "StackdriverLoggingTests",
            file: #file,
            function: #function,
            line: #line
        )

        var foundLines = false
        for line in try String(contentsOfFile: tmpPath).split(separator: "\n") {
            XCTAssertTrue(line.contains("\"@type\": \"type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent\","))
            foundLines = true
        }
        XCTAssertTrue(foundLines)
        
        handler.log(
            level: .info,
            message: "No error",
            metadata: nil,
            source: "StackdriverLoggingTests",
            file: #file,
            function: #function,
            line: #line
        )

        let lastLine = try XCTUnwrap(String(contentsOfFile: tmpPath).split(separator: "\n").last)
            XCTAssertFalse(lastLine.contains("\"@type\": \"type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent\","))
        
        try FileManager.default.removeItem(atPath: tmpPath)
        try tp.syncShutdownGracefully()
    }
}
