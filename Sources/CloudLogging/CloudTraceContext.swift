public import Logging

/// The trace a request belongs to, read from the headers Cloud Run forwards.
public struct CloudTraceContext: Sendable, Equatable {
    /// 32 lowercase hex characters.
    public var traceID: String
    public var sampled: Bool

    public init?(traceID: String, sampled: Bool) {
        let traceID = traceID.lowercased()
        guard traceID.utf8.count == 32, traceID.utf8.allSatisfy(\.isHexDigit), traceID.utf8.contains(where: { $0 != UInt8(ascii: "0") })
        else { return nil }
        self.traceID = traceID
        self.sampled = sampled
    }

    /// W3C `traceparent`: `00-<trace-id>-<parent-id>-<flags>`.
    public init?(traceparent: String) {
        let parts = traceparent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0].utf8.count == 2, parts[0] != "ff", let flags = UInt8(parts[3], radix: 16)
        else { return nil }
        self.init(traceID: String(parts[1]), sampled: flags & 1 == 1)
    }

    /// `X-Cloud-Trace-Context`: `<trace-id>/<span-id>;o=<0|1>`, where the span and option are optional.
    public init?(xCloudTraceContext: String) {
        let traceID = xCloudTraceContext.prefix { $0 != "/" && $0 != ";" }
        self.init(traceID: String(traceID), sampled: xCloudTraceContext.hasSuffix(";o=1"))
    }

    public init?(traceparent: String?, xCloudTraceContext: String?) {
        if let traceparent, let context = CloudTraceContext(traceparent: traceparent) {
            self = context
        } else if let xCloudTraceContext, let context = CloudTraceContext(xCloudTraceContext: xCloudTraceContext) {
            self = context
        } else {
            return nil
        }
    }

    /// Metadata that makes Logs Explorer group the entry under its request.
    public func metadata(projectID: String) -> Logger.Metadata {
        [
            "logging.googleapis.com/trace": "projects/\(projectID)/traces/\(self.traceID)",
            "logging.googleapis.com/trace_sampled": .stringConvertible(self.sampled),
        ]
    }
}

extension UInt8 {
    fileprivate var isHexDigit: Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(self)
    }
}
