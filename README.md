# StackdriverLogging

A [swift-log](https://github.com/apple/swift-log) handler that writes one JSON line per log event to stdout, in the [structured logging](https://docs.cloud.google.com/logging/docs/structured-logging) format Cloud Logging parses on Cloud Run, plus an optional Vapor 5 middleware that ties log lines to the request's Cloud Trace.

Version 5 is a rewrite with new module and type names; see [Migrating from 4.x](#migrating-from-4x).

## Installation

```swift
.package(url: "https://github.com/brainfinance/StackdriverLogging.git", from: "5.0.0"),
```

```swift
.target(name: "App", dependencies: [
    .product(name: "CloudLogging", package: "StackdriverLogging"),
]),
```

For `CloudTraceMiddleware`, enable the `Vapor` trait and add the `CloudLoggingVapor` product. Without the trait, Vapor is not part of your dependency graph and `CloudLoggingVapor` is empty.

```swift
.package(url: "https://github.com/brainfinance/StackdriverLogging.git", from: "5.0.0", traits: ["Vapor"]),
```

```swift
.product(name: "CloudLoggingVapor", package: "StackdriverLogging"),
```

Requires swift-tools 6.4 and macOS 26.2 (any Linux with Swift 6.4).

## Usage

Bootstrap first thing in `main`, so a failed startup is still logged as JSON:

```swift
import CloudLogging

CloudLoggingHandler.bootstrap(logLevel: .info)
```

With Vapor 5, register the middleware first so every middleware's logs carry the trace, and log through `Logger.current` (Vapor 5 binds one per request with `request-id`):

```swift
import CloudLoggingVapor

app.middleware.use(CloudTraceMiddleware(projectID: projectID), at: .beginning)
```

```swift
Logger.current.info("Signed in", metadata: ["userId": "\(userID)"])
Logger.current.error("Payment failed", error: error)
```

The trace needs the project ID. Cloud Run does not set `GOOGLE_CLOUD_PROJECT`; read it from the metadata server (`http://metadata.google.internal/computeMetadata/v1/project/project-id` with `Metadata-Flavor: Google`).

## What a line looks like

```json
{"severity":"INFO","message":"Request","timestamp":{"seconds":1792261884,"nanos":355506000},"logging.googleapis.com/sourceLocation":{"file":"Vapor/RouteLoggingMiddleware.swift","line":"19","function":"respond(to:chainingTo:)"},"logging.googleapis.com/trace":"projects/my-project/traces/4bf92f3577b34da6a3ce929d0e0e4736","logging.googleapis.com/trace_sampled":true,"request-id":"CA4B565B-...","method":"GET","path":"/hello"}
```

- `severity`, `message`, `timestamp` and `logging.googleapis.com/sourceLocation` are always written and can't be overridden by metadata.
- `.error` and `.critical` lines get the [Error Reporting](https://docs.cloud.google.com/error-reporting/docs/formatting-error-messages) `@type`; turn it off with `reportErrors: false`.
- An error passed with `error:` is written as `"error":{"type":…,"message":…}`.
- Metadata is written as-is at the top level, so `httpRequest`, `logging.googleapis.com/labels`, `logging.googleapis.com/operation` and the other [special fields](https://docs.cloud.google.com/logging/docs/agent/logging/configuration#special-fields) work when you set them. `Bool`, integer and finite floating-point values from `.stringConvertible` are written as JSON booleans and numbers; everything else is a string.
- Metadata values go through `transform` first, when set; see [Transforming metadata](#transforming-metadata).

Each line is written with one `write(2)` on the caller's thread, under a lock: lines stay ordered, never interleave, and are not lost on crash or shutdown.

`CloudTraceMiddleware` reads `traceparent`, falling back to `X-Cloud-Trace-Context`, and does nothing when neither header is valid. `CloudTraceContext` does the header parsing and is in `CloudLogging`, for other frameworks.

## Transforming metadata

`transform` is called on every metadata value, nested ones included, before it is written. It returns a replacement, or `nil` to leave the value out, so it can redact, hash, truncate or drop values.

For example, redacting values marked with a sensitivity attribute. swift-log lets you attach your own [attributes](https://github.com/apple/swift-log/blob/main/Sources/Logging/Docs.docc/Proposals/SLG-0004-metadata-value-attributes.md) to metadata values, and `transform` can read them:

```swift
enum Sensitivity: Int64, Logger.MetadataValueAttributes.Attribute, Sendable {
    case sensitive = 1
    case `public` = 2
}

extension Logger.MetadataValue.StringInterpolation {
    mutating func appendInterpolation<T: CustomStringConvertible & Sendable>(_ value: T, sensitivity: Sensitivity) {
        self.appendInterpolation(value, attributes: { $0[Sensitivity.self] = sensitivity })
    }
}

CloudLoggingHandler.bootstrap(transform: { value in
    value.attributes[Sensitivity.self] == .sensitive ? "<redacted>" : value
})

logger.info("Signed in", metadata: ["email": "\(email, sensitivity: .sensitive)"])
// {"severity":"INFO","message":"Signed in",…,"email":"<redacted>"}
```

## Migrating from 4.x

| 4.x | 5.0 |
|---|---|
| `import StackdriverLogging` | `import CloudLogging` |
| `StackdriverLogHandler(destination: .stdout)` | `CloudLoggingHandler()`, or `CloudLoggingHandler.bootstrap(logLevel:)` |
| `Destination.file(_:)` | removed; lines go to stdout only |
| `threadPool:` | removed; lines are written synchronously |
| `sourceLocationLogLevel:` | removed; source location is always written |
| `enableErrorTagging:` (off by default) | `reportErrors:` (on by default) |
| `Logger.setHTTPRequestMetadata(…)` | set `httpRequest` metadata yourself, or rely on Cloud Run's request log grouped by trace |
| `Logger.setLogEntryOperationMetadata(…)` | set `logging.googleapis.com/operation` metadata yourself |
| `Date` metadata as ISO 8601, `Data` as base64, `NSNull` as `null` | written as their `description` string |
| swift-nio, swift-system dependencies | swift-log only (Vapor with the `Vapor` trait) |

What changed in the output, and why:

- `sourceLocation` and `operation` were written without the `logging.googleapis.com/` prefix, so Cloud Logging left them in `jsonPayload` and the entry's source location was empty.
- `timestamp` was written as a string, which Cloud Logging only accepts under `time`, so entries got the time Cloud Run read the line instead. It is now `{seconds, nanos}`.
- An `Error` passed to the logger was dropped; it's now written under `error`.
- Lines were written from a thread pool, and lines still queued when the pool shut down were lost: a 20,000-line burst followed by `shutdownGracefully()` wrote 1,179 lines.

Per line, with 8 metadata keys including a nested dictionary, written to `/dev/null`, 4.x timed until its thread pool had written every line:

| | 5.0 | 4.2 |
|---|---|---|
| macOS, M-series | 3.7 µs | 13.7 µs |
| Linux (Docker, swift:6.4-noble, arm64) | 2.5 µs | 56 µs |

## Development

```sh
swift test                  # CloudLogging
swift test --traits Vapor   # also CloudLoggingVapor
```
