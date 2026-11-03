import Foundation

/// Payload-free local delivery outcome. Diagnostic callbacks never receive event contents.
public struct TraceDiagnostic {
    public let outcome: String
    public let reason: String
    public let count: Int
    public let queueSize: Int
    public let httpStatus: Int
}

/// Bounded local counters for queue and delivery health.
public struct TraceDiagnosticsSnapshot {
    public let queueSize: Int
    public let queued: UInt64
    public let accepted: UInt64
    public let rejected: UInt64
    public let dropped: UInt64
    public let queueFull: UInt64
    public let retries: UInt64
    public let networkFailures: UInt64
    public let beforeSendDropped: UInt64
    public let callbackFailures: UInt64
    public let lastHTTPStatus: Int
}

/// Optional native debug identity supplied by the caller; the SDK does not infer symbol data.
public struct TraceFrame {
    public var function: String?
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var inApp: Bool?
    public var module: String?
    public var debugID: String?
    public var instructionAddress: String?
    public var imageAddress: String?
    public var architecture: String?
    public var buildID: String?

    public init(function: String? = nil, file: String? = nil, line: Int? = nil, column: Int? = nil,
                inApp: Bool? = nil, module: String? = nil, debugID: String? = nil,
                instructionAddress: String? = nil, imageAddress: String? = nil,
                architecture: String? = nil, buildID: String? = nil) {
        self.function = function; self.file = file; self.line = line; self.column = column
        self.inApp = inApp; self.module = module; self.debugID = debugID
        self.instructionAddress = instructionAddress; self.imageAddress = imageAddress
        self.architecture = architecture; self.buildID = buildID
    }

    var payload: [String: Any] {
        var value: [String: Any] = [:]
        if let function { value["fn"] = function }
        if let file { value["file"] = file }
        if let line { value["line"] = line }
        if let column { value["col"] = column }
        if let inApp { value["in_app"] = inApp }
        if let module { value["module"] = module }
        if let debugID { value["debug_id"] = debugID }
        if let instructionAddress { value["instruction_addr"] = instructionAddress }
        if let imageAddress { value["image_addr"] = imageAddress }
        if let architecture { value["arch"] = architecture }
        if let buildID { value["build_id"] = buildID }
        return value
    }
}

final class TraceDiagnosticState {
    private let lock = NSLock()
    private var values = [String: UInt64]()
    private var queueSize = 0
    private var lastHTTPStatus = 0

    func setQueueSize(_ value: Int) { lock.lock(); queueSize = max(0, value); lock.unlock() }
    func increment(_ outcome: String, by count: Int = 1, status: Int = 0) {
        lock.lock()
        values[outcome, default: 0] &+= UInt64(max(0, count))
        if status > 0 { lastHTTPStatus = status }
        lock.unlock()
    }
    func snapshot() -> TraceDiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return TraceDiagnosticsSnapshot(queueSize: queueSize, queued: values["queued", default: 0],
            accepted: values["accepted", default: 0], rejected: values["rejected", default: 0],
            dropped: values["dropped", default: 0], queueFull: values["queue_full", default: 0],
            retries: values["retry", default: 0], networkFailures: values["network", default: 0],
            beforeSendDropped: values["before_send", default: 0], callbackFailures: values["callback_failure", default: 0],
            lastHTTPStatus: lastHTTPStatus)
    }
}

/// Configuration for a DELG Trace client.
public struct TraceOptions {
    public typealias BeforeSend = (inout [String: Any]) -> Bool
    public typealias OnDiagnostic = (TraceDiagnostic) throws -> Void

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
    /// Receives payload-free local outcomes. A thrown error is ignored and counted.
    public var onDiagnostic: OnDiagnostic?

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
        beforeSend: BeforeSend? = nil,
        onDiagnostic: OnDiagnostic? = nil
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
        self.onDiagnostic = onDiagnostic
    }
}
