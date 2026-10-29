import Foundation

/// A manually instrumented operation. End a span once its work completes.
public final class TraceSpan {
    public let traceID: String
    public let spanID: String
    public let parentID: String?
    public let sampled: Bool
    public let isSegment: Bool

    private weak var client: TraceClient?
    private let lock = NSLock()
    private let startTime: Double
    private var name: String
    private let operation: String
    private var status = "ok"
    private var attributes: [String: String] = [:]
    private var ended = false

    init(
        client: TraceClient,
        traceID: String,
        spanID: String,
        parentID: String?,
        sampled: Bool,
        isSegment: Bool,
        name: String,
        operation: String,
        startTime: Double = Date().timeIntervalSince1970 * 1_000
    ) {
        self.client = client
        self.traceID = traceID
        self.spanID = spanID
        self.parentID = parentID
        self.sampled = sampled
        self.isSegment = isSegment
        self.name = name
        self.operation = operation
        self.startTime = startTime
    }

    /// W3C trace context suitable for passing to an explicitly instrumented downstream service.
    public var traceparent: String {
        "00-\(traceID)-\(spanID)-\(sampled ? "01" : "00")"
    }

    public func setName(_ name: String) {
        lock.lock()
        self.name = name
        lock.unlock()
    }

    /// Use `ok` or `error` for the standard status values.
    public func setStatus(_ status: String) {
        lock.lock()
        self.status = String(status.prefix(30))
        lock.unlock()
    }

    /// Attributes should be low-cardinality and must not contain user data, credentials, or request bodies.
    public func setAttribute(_ key: String, value: String) {
        lock.lock()
        if attributes.count < 50 || attributes[key] != nil {
            attributes[String(key.prefix(200))] = String(value.prefix(300))
        }
        lock.unlock()
    }

    /// Ends and queues the span once. Unsampled spans still carry IDs for manual propagation.
    public func end() {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        var event: [String: Any] = [
            "type": "span",
            "trace_id": traceID,
            "span_id": spanID,
            "name": String(name.prefix(300)),
            "op": String(operation.prefix(50)),
            "start": startTime,
            "end": Date().timeIntervalSince1970 * 1_000,
            "status": status,
            "segment": isSegment,
            "attrs": attributes
        ]
        if let parentID { event["parent_id"] = parentID }
        lock.unlock()

        if sampled {
            client?.enqueue(event)
        }
    }
}
