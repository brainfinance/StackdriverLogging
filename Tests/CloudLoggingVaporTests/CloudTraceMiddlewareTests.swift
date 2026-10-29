#if Vapor
import CloudLoggingVapor
import HTTPTypes
import Logging
import RoutingKit
import Testing
import Vapor
import VaporTesting

let traceID = "4bf92f3577b34da6a3ce929d0e0e4736"

@Test func addsTraceToCurrentLogger() async throws {
    try await withApp { app in
        app.middleware.use(CloudTraceMiddleware(projectID: "proj"), at: .beginning)
        app.get("trace") { _ in
            Logger.current[metadataKey: "logging.googleapis.com/trace"]?.description ?? "none"
        }

        try await app.testing { client in
            let traced = try await client.get("/trace", headers: [.traceparent: "00-\(traceID)-00f067aa0ba902b7-01"])
            #expect(try #require(await traced.body.string()) == "projects/proj/traces/\(traceID)")

            let untraced = try await client.get("/trace")
            #expect(try #require(await untraced.body.string()) == "none")
        }
    }
}
#endif
