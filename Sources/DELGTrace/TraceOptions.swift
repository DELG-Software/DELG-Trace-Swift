import Foundation

/// Configuration for a DELG Trace client.
public struct TraceOptions {
    public typealias BeforeSend = (inout [String: Any]) -> Bool

    /// Ingest token. An empty token disables reporting and avoids disk or network work.
    public var token: String
    /// Base URL before `/ingest/v1/events` (defaults to `https://api.delg.dev/trace`).
    public var endpoint: String
    public var release: String
    public var environment: String
    /// Optional caller supplied server or instance label. Device identifiers are never collected automatically.
    public var server: String
    /// Fraction of traces to send, from 0 through 1. Errors are captured at every rate.
    public var tracesSampleRate: Double
    /// Image-name prefixes classified as application frames. Unmatched frames are marked out of app.
    public var inAppFrameImagePrefixes: [String]
    /// Root directory for the offline queue. Defaults to the app's Application Support directory.
    public var storageDirectory: URL?
    /// Source of the URLSession configuration, useful for custom networking and tests.
    /// TraceClient creates its own session from this configuration to reject redirects;
    /// delegates attached to this session are not used.
    /// Background session configurations disable this client because they always follow redirects.
    public var session: URLSession
    /// Automatic queue drain interval. Set to 0 to disable automatic sending.
    public var automaticFlushInterval: TimeInterval
    /// Called with each event before it is queued. Mutate to redact fields; return false to drop it.
    public var beforeSend: BeforeSend?

    public init(
        token: String = "",
        endpoint: String = "https://api.delg.dev/trace",
        release: String = "",
        environment: String = "production",
        server: String = "",
        tracesSampleRate: Double = 0,
        inAppFrameImagePrefixes: [String] = [],
        storageDirectory: URL? = nil,
        session: URLSession = .shared,
        automaticFlushInterval: TimeInterval = 1,
        beforeSend: BeforeSend? = nil
    ) {
        self.token = token
        self.endpoint = endpoint
        self.release = release
        self.environment = environment
        self.server = server
        self.tracesSampleRate = tracesSampleRate
        self.inAppFrameImagePrefixes = inAppFrameImagePrefixes
        self.storageDirectory = storageDirectory
        self.session = session
        self.automaticFlushInterval = automaticFlushInterval
        self.beforeSend = beforeSend
    }
}
