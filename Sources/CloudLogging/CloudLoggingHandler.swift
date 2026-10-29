public import Logging

/// Writes each log event as one JSON line in the format Cloud Logging parses from Cloud Run stdout.
public struct CloudLoggingHandler: LogHandler {
    /// Called on every metadata value, nested ones included, before it is written. Returns a replacement, or `nil` to
    /// leave the value out. For example, redacting values marked with a `Sensitivity` attribute you define:
    ///
    /// ```swift
    /// CloudLoggingHandler.bootstrap(transform: { value in
    ///     value.attributes[Sensitivity.self] == .sensitive ? "<redacted>" : value
    /// })
    /// ```
    public typealias Transform = @Sendable (Logger.MetadataValue) -> Logger.MetadataValue?

    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?
    public var logLevel: Logger.Level

    private let output: LogOutput
    private let reportErrors: Bool
    private let transform: Transform?

    /// - Parameters:
    ///   - reportErrors: Tag `.error` and `.critical` entries so Error Reporting picks them up.
    ///   - transform: Rewrites or drops metadata values before they are written; see ``Transform``.
    public init(
        logLevel: Logger.Level = .info,
        metadataProvider: Logger.MetadataProvider? = nil,
        reportErrors: Bool = true,
        transform: Transform? = nil
    ) {
        self.init(
            logLevel: logLevel, metadataProvider: metadataProvider, output: .standardOutput, reportErrors: reportErrors,
            transform: transform)
    }

    // Internal so tests can capture lines in a file instead of stdout.
    init(
        logLevel: Logger.Level = .info,
        metadataProvider: Logger.MetadataProvider? = nil,
        output: LogOutput,
        reportErrors: Bool = true,
        transform: Transform? = nil
    ) {
        self.logLevel = logLevel
        self.metadataProvider = metadataProvider
        self.output = output
        self.reportErrors = reportErrors
        self.transform = transform
    }

    public static func bootstrap(
        logLevel: Logger.Level = .info,
        metadataProvider: Logger.MetadataProvider? = nil,
        reportErrors: Bool = true,
        transform: Transform? = nil
    ) {
        LoggingSystem.bootstrap(
            { _, provider in
                CloudLoggingHandler(logLevel: logLevel, metadataProvider: provider, reportErrors: reportErrors, transform: transform)
            },
            metadataProvider: metadataProvider
        )
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { self.metadata[key] }
        set { self.metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        var metadata = self.metadata
        if let provided = self.metadataProvider?.get(), !provided.isEmpty {
            metadata.merge(provided) { current, _ in current }
        }
        if let explicit = event.metadata, !explicit.isEmpty {
            metadata.merge(explicit) { _, new in new }
        }
        var encoder = LogEntryEncoder(transform: self.transform)
        encoder.encode(event, metadata: metadata, timestamp: .now(), reportErrors: self.reportErrors)
        self.output.write(encoder.bytes)
    }
}
