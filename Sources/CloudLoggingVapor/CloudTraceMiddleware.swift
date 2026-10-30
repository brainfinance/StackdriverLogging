#if Vapor
import CloudLogging
import HTTPTypes
import Logging
public import Vapor

/// Adds the request's Cloud Trace ID to `Logger.current` for the rest of the request, so its log lines
/// are grouped under the request in Logs Explorer. Register it first so every middleware's logs carry it:
///
/// ```swift
/// app.middleware.use(CloudTraceMiddleware(projectID: "my-project"), at: .beginning)
/// ```
public struct CloudTraceMiddleware: Middleware {
    public let projectID: String

    public init(projectID: String) {
        self.projectID = projectID
    }

    public func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard
            let context = CloudTraceContext(
                traceparent: request.headers[.traceparent],
                xCloudTraceContext: request.headers[.xCloudTraceContext]
            )
        else {
            return try await next.respond(to: request)
        }
        return try await withLogger(mergingMetadata: context.metadata(projectID: self.projectID)) { _ in
            try await next.respond(to: request)
        }
    }
}

extension HTTPField.Name {
    fileprivate static let xCloudTraceContext = HTTPField.Name("X-Cloud-Trace-Context")!
}
#else
@available(*, unavailable, message: "Enable this package's Vapor trait to use CloudTraceMiddleware")
public struct CloudTraceMiddleware {
    public init(projectID: String) {}
}
#endif
