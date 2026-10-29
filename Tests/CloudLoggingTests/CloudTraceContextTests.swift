import Logging
import Testing

@testable import CloudLogging

let traceID = "4bf92f3577b34da6a3ce929d0e0e4736"

@Test func parsesTraceparent() {
    #expect(CloudTraceContext(traceparent: "00-\(traceID)-00f067aa0ba902b7-01") == CloudTraceContext(traceID: traceID, sampled: true))
    #expect(CloudTraceContext(traceparent: "00-\(traceID.uppercased())-00f067aa0ba902b7-00")?.sampled == false)
    #expect(CloudTraceContext(traceparent: "00-00000000000000000000000000000000-00f067aa0ba902b7-01") == nil)
    #expect(CloudTraceContext(traceparent: "ff-\(traceID)-00f067aa0ba902b7-01") == nil)
    #expect(CloudTraceContext(traceparent: "00-\(traceID)") == nil)
    #expect(CloudTraceContext(traceparent: "00-xyz-00f067aa0ba902b7-01") == nil)
}

@Test func parsesXCloudTraceContext() {
    #expect(CloudTraceContext(xCloudTraceContext: "\(traceID)/1234567890;o=1") == CloudTraceContext(traceID: traceID, sampled: true))
    #expect(CloudTraceContext(xCloudTraceContext: "\(traceID)/1234567890")?.sampled == false)
    #expect(CloudTraceContext(xCloudTraceContext: traceID)?.traceID == traceID)
    #expect(CloudTraceContext(xCloudTraceContext: "nope/1;o=1") == nil)
}

@Test func prefersTraceparent() {
    let other = "0af7651916cd43dd8448eb211c80319c"
    let context = CloudTraceContext(traceparent: "00-\(traceID)-00f067aa0ba902b7-01", xCloudTraceContext: "\(other)/1;o=1")
    #expect(context?.traceID == traceID)
    #expect(CloudTraceContext(traceparent: "garbage", xCloudTraceContext: "\(other)/1;o=1")?.traceID == other)
    #expect(CloudTraceContext(traceparent: nil, xCloudTraceContext: nil) == nil)
}

@Test func buildsTraceMetadata() throws {
    let metadata = try #require(CloudTraceContext(traceID: traceID, sampled: true)).metadata(projectID: "production-brainfinance")
    #expect(metadata["logging.googleapis.com/trace"] == .string("projects/production-brainfinance/traces/\(traceID)"))
    #expect(metadata["logging.googleapis.com/trace_sampled"]?.description == "true")
}
