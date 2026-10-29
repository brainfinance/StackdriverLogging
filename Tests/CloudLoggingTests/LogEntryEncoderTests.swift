import Foundation
import Logging
import Testing

@testable import CloudLogging

struct Failure: Error, CustomStringConvertible {
    var description: String { "upstream said \"no\"" }
}

func encode(
    _ level: Logger.Level = .info,
    _ message: Logger.Message = "hello",
    error: (any Error)? = nil,
    metadata: Logger.Metadata = [:],
    reportErrors: Bool = true,
    transform: CloudLoggingHandler.Transform? = nil
) throws -> (line: String, json: [String: Any]) {
    var encoder = LogEntryEncoder(transform: transform)
    let event = LogEvent(
        level: level, message: message, error: error, metadata: nil, source: "App",
        file: "App/routes.swift", function: "boot(_:)", line: 42)
    encoder.encode(
        event, metadata: metadata, timestamp: Timestamp(seconds: 1_792_195_200, nanos: 123_456_789),
        reportErrors: reportErrors)
    let line = String(decoding: encoder.bytes, as: UTF8.self)
    let json = try #require(JSONSerialization.jsonObject(with: Data(encoder.bytes)) as? [String: Any])
    return (line, json)
}

@Test func writesCloudLoggingSpecialFields() throws {
    let (line, json) = try encode(.notice, "started")
    #expect(line.hasSuffix("}\n"))
    #expect(line.firstIndex(of: "\n") == line.index(before: line.endIndex))
    #expect(json["severity"] as? String == "NOTICE")
    #expect(json["message"] as? String == "started")
    let timestamp = try #require(json["timestamp"] as? [String: Int])
    #expect(timestamp == ["seconds": 1_792_195_200, "nanos": 123_456_789])
    let location = try #require(json["logging.googleapis.com/sourceLocation"] as? [String: String])
    #expect(location == ["file": "App/routes.swift", "line": "42", "function": "boot(_:)"])
    #expect(json["@type"] == nil)
}

@Test(arguments: [
    (Logger.Level.trace, "DEBUG"), (.debug, "DEBUG"), (.info, "INFO"), (.notice, "NOTICE"),
    (.warning, "WARNING"), (.error, "ERROR"), (.critical, "CRITICAL"),
])
func mapsSeverity(level: Logger.Level, severity: String) throws {
    #expect(try encode(level).json["severity"] as? String == severity)
}

@Test func tagsErrorsForErrorReporting() throws {
    let reported = try encode(.error, "payment failed", error: Failure())
    #expect(reported.json["@type"] as? String == "type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent")
    let error = try #require(reported.json["error"] as? [String: String])
    #expect(error["type"] == "CloudLoggingTests.Failure")
    #expect(error["message"] == "upstream said \"no\"")

    struct LocalFailure: Error {}
    let local = try #require(try encode(.error, error: LocalFailure()).json["error"] as? [String: String])
    #expect(local["type"] == "CloudLoggingTests.LocalFailure")

    #expect(try encode(.warning, error: Failure()).json["@type"] == nil)
    #expect(try encode(.critical, reportErrors: false).json["@type"] == nil)
}

@Test func encodesMetadataWithJSONTypes() throws {
    let (_, json) = try encode(metadata: [
        "user": "jb",
        "count": .stringConvertible(3),
        "small": .stringConvertible(UInt8(7)),
        "ratio": .stringConvertible(0.5),
        "nan": .stringConvertible(Double.nan),
        "flag": .stringConvertible(true),
        "tags": ["a", .stringConvertible(1)],
        "nested": ["level": ["deep": "yes"]],
        "logging.googleapis.com/labels": ["team": "platform"],
    ])
    #expect(json["user"] as? String == "jb")
    #expect(json["count"] as? Int == 3)
    #expect(json["small"] as? Int == 7)
    #expect(json["ratio"] as? Double == 0.5)
    #expect(json["nan"] as? String == "nan")
    #expect(json["flag"] as? Bool == true)
    #expect((json["tags"] as? [Any])?.count == 2)
    #expect(((json["nested"] as? [String: Any])?["level"] as? [String: String]) == ["deep": "yes"])
    #expect(json["logging.googleapis.com/labels"] as? [String: String] == ["team": "platform"])
}

@Test func escapesStrings() throws {
    let tricky = "quote \" backslash \\ newline \n tab \t bell \u{07} emoji 🦀 accent é"
    let (line, json) = try encode(.info, Logger.Message(stringLiteral: tricky), metadata: [tricky: "\(tricky)"])
    #expect(json["message"] as? String == tricky)
    #expect(json[tricky] as? String == tricky)
    #expect(line.contains(#"\u0007"#))
    #expect(line.filter { $0 == "\n" }.count == 1)
}

enum Sensitivity: Int64, Logger.MetadataValueAttributes.Attribute, Sendable {
    case sensitive = 1
    case `public` = 2
}

extension Logger.MetadataValue.StringInterpolation {
    mutating func appendInterpolation<T: CustomStringConvertible & Sendable>(_ value: T, sensitivity: Sensitivity) {
        self.appendInterpolation(value, attributes: { $0[Sensitivity.self] = sensitivity })
    }
}

@Test func transformsMetadataValues() throws {
    let email = "ops@brainfinance.com"
    let metadata: Logger.Metadata = [
        "email": "\(email, sensitivity: .sensitive)",
        "contacts": ["\(email, sensitivity: .sensitive)", "visible"],
        "action": "\(email, sensitivity: .public)",
        "nested": ["internal": "drop", "kept": "yes"],
    ]
    let (line, json) = try encode(metadata: metadata) { value in
        if value.attributes[Sensitivity.self] == .sensitive { return "<redacted>" }
        return value.description == "drop" ? nil : value
    }
    #expect(json["email"] as? String == "<redacted>")
    #expect(json["contacts"] as? [String] == ["<redacted>", "visible"])
    #expect(json["action"] as? String == email)
    #expect(json["nested"] as? [String: String] == ["kept": "yes"])
    #expect(line.components(separatedBy: email).count == 2)
    #expect(try encode(metadata: metadata).json["email"] as? String == email)
}

@Test func reservedKeysCannotBeOverridden() throws {
    let (line, json) = try encode(
        .error, error: Failure(),
        metadata: ["severity": "DEBUG", "message": "spoofed", "timestamp": "x", "error": "dup", "@type": "x"])
    #expect(json["severity"] as? String == "ERROR")
    #expect(json["message"] as? String == "hello")
    #expect(json["error"] is [String: String])
    #expect(line.components(separatedBy: "\"severity\"").count == 2)
    #expect(line.components(separatedBy: "\"error\"").count == 2)
}

func canonical(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

@Test func encodesInterleavedArraysAndObjects() throws {
    let json = try encode(metadata: [
        "orders": [
            ["id": .stringConvertible(1), "items": [["sku": "a", "tags": ["x", "y"]], ["sku": "b", "tags": []]]],
            ["id": .stringConvertible(2), "items": [], "meta": [:]],
        ],
        "matrix": [[.stringConvertible(1), .stringConvertible(2)], [], [["deep": [.stringConvertible(true)]]]],
    ]).json
    let expected: [String: Any] = [
        "orders": [
            ["id": 1, "items": [["sku": "a", "tags": ["x", "y"]], ["sku": "b", "tags": [String]()]]],
            ["id": 2, "items": [Any](), "meta": [String: Any]()],
        ],
        "matrix": [[1, 2], [Any](), [["deep": [true]]]],
    ]
    #expect(try canonical(["orders": json["orders"]!, "matrix": json["matrix"]!]) == canonical(expected))
}

@Test func transformDropsElementsAtAnyDepth() throws {
    let json = try encode(metadata: [
        "list": ["drop", "a", "drop", ["drop"], ["k": "drop", "v": ["drop", "b"]], "drop"],
        "object": ["first": "drop", "kept": [["drop": "no", "k": "drop"]], "last": "drop"],
        "gone": "drop",
    ]) { $0.description == "drop" ? nil : $0 }.json
    #expect(json["gone"] == nil)
    #expect(try canonical(json["list"]!) == canonical(["a", [Any](), ["v": ["b"]]] as [Any]))
    #expect(try canonical(json["object"]!) == canonical(["kept": [["drop": "no"]]]))
}
