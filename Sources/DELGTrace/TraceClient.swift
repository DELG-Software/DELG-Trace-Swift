import CryptoKit
import Foundation

/// Thread-safe event client for native Swift applications.
///
/// Retain the client for the lifetime of the app. Capture APIs only build and queue local events;
/// URLSession sends them asynchronously. This client does not install crash handlers.
public final class TraceClient: NSObject {
    public static let defaultEndpoint = "https://api.delg.dev/trace"
    private static let sdkVersion = "swift/0.1.0"
    private static let maxQueueEvents = 1_000
    private static let maxQueueBytes = 8 * 1_024 * 1_024
    private static let maxEventBytes = 64 * 1_024
    private static let maxBodyBytes = 768 * 1_024
    private static let maxBatchEvents = 100

    private let options: TraceOptions
    private let transportSession: URLSession
    private let transportDelegate: RedirectBlockingSessionDelegate
    private let enabledValue: Bool
    private let stateQueue: DispatchQueue
    private let queueURL: URL?
    private let configuredIngestURL: String
    private let encoder: JSONEncoder
    private var records: [QueuedEvent] = []
    private var queueBytes = 0
    private var breadcrumbs: [[String: Any]] = []
    private var tags: [String: String] = [:]
    private var contexts: [String: [String: String]] = [:]
    private var sending = false
    private var activeTask: URLSessionDataTask?
    private var pausedUntil = Date.distantPast
    private var scheduledPump: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var flushWaiters: [FlushWaiter] = []
    private var disposing = false
    private var disposed = false

    /// Swift initializer for the full configuration surface.
    public init(options: TraceOptions = TraceOptions()) {
        let eventEncoder = JSONEncoder()
        eventEncoder.outputFormatting = [.sortedKeys]
        self.options = options
        self.stateQueue = DispatchQueue(label: "dev.delg.trace.swift.\(UUID().uuidString)", qos: .utility)
        self.encoder = eventEncoder
        let redirectDelegate = RedirectBlockingSessionDelegate()
        self.transportDelegate = redirectDelegate
        let sessionConfiguration = options.session.configuration
        let usesBackgroundSession = sessionConfiguration.identifier != nil
        self.transportSession = URLSession(
            configuration: usesBackgroundSession ? .ephemeral : sessionConfiguration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        let ingestURL = Self.ingestURL(for: options.endpoint)
        self.enabledValue = !options.token.isEmpty && !usesBackgroundSession && Self.isValidIngestURL(ingestURL)
        self.configuredIngestURL = ingestURL
        self.queueURL = Self.makeQueueURL(options: options, ingestURL: ingestURL)
        super.init()

        guard enabledValue else { return }
        if let queueURL {
            records = Self.loadQueue(at: queueURL, expectedEndpoint: configuredIngestURL)
            queueBytes = records.reduce(0) { $0 + $1.event.count }
            persistQueue()
        }

        let interval = max(0, options.automaticFlushInterval)
        if interval > 0 {
            let source = DispatchSource.makeTimerSource(queue: stateQueue)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [weak self] in self?.pump() }
            source.resume()
            timer = source
        }
    }

    /// Objective-C convenience initializer with the common configuration fields.
    @objc(initWithToken:release:environment:endpoint:)
    public convenience init(token: String, release: String, environment: String, endpoint: String) {
        self.init(options: TraceOptions(token: token, endpoint: endpoint, release: release, environment: environment))
    }

    deinit {
        timer?.cancel()
        scheduledPump?.cancel()
        activeTask?.cancel()
        transportSession.invalidateAndCancel()
    }

    /// Whether this instance has a non-empty token and valid HTTP(S) ingest endpoint.
    @objc public var isEnabled: Bool { enabledValue }

    /// Captures a caller supplied Swift error. The stack is captured at the call site, on that thread.
    public func capture(
        error: Error,
        level: String = "error",
        tags extraTags: [String: String] = [:],
        contexts extraContexts: [String: [String: String]] = [:],
        span: TraceSpan? = nil,
        userHash: String? = nil,
        fingerprint: [String]? = nil
    ) {
        guard enabledValue else { return }
        let frames = Self.callSiteFrames(inAppImagePrefixes: options.inAppFrameImagePrefixes)
        let exceptions = Self.exceptionPayloads(for: error, frames: frames)
        var event = errorEvent(level: level, extraTags: extraTags, extraContexts: extraContexts, span: span, userHash: userHash, fingerprint: fingerprint)
        event["exceptions"] = exceptions
        enqueueWithState(event)
    }

    /// Objective-C compatible NSError capture entry point.
    @objc(captureError:)
    public func captureError(_ error: NSError) {
        capture(error: error as Error)
    }

    /// Captures a message without a stack trace.
    public func captureMessage(
        _ message: String,
        level: String = "info",
        tags extraTags: [String: String] = [:],
        contexts extraContexts: [String: [String: String]] = [:],
        span: TraceSpan? = nil,
        userHash: String? = nil,
        fingerprint: [String]? = nil
    ) {
        guard enabledValue else { return }
        var event = errorEvent(level: level, extraTags: extraTags, extraContexts: extraContexts, span: span, userHash: userHash, fingerprint: fingerprint)
        event["message"] = String(message.prefix(4_000))
        enqueueWithState(event)
    }

    /// Objective-C compatible message capture entry point.
    @objc(captureMessage:level:)
    public func captureMessageForObjectiveC(_ message: String, level: String) {
        captureMessage(message, level: level, tags: [:], contexts: [:], span: nil, userHash: nil, fingerprint: nil)
    }

    /// Queues a structured log line. No log source is collected automatically.
    public func log(_ level: String, body: String, attributes: [String: String] = [:], span: TraceSpan? = nil) {
        guard enabledValue else { return }
        var event: [String: Any] = [
            "type": "log",
            "ts": Self.timestamp(),
            "level": Self.normalizedLogLevel(level),
            "body": String(body.prefix(8_000)),
            "attrs": Self.boundedAttributes(attributes)
        ]
        if let span {
            event["trace_id"] = span.traceID
            event["span_id"] = span.spanID
        }
        enqueueWithState(event)
    }

    /// Adds an explicit breadcrumb. The client keeps at most the latest 50.
    public func addBreadcrumb(category: String, level: String = "info", message: String, data: [String: String] = [:]) {
        guard enabledValue else { return }
        stateQueue.async { [weak self] in
            guard let self, !self.disposing, !self.disposed else { return }
            self.breadcrumbs.append([
                "ts": Self.timestamp(),
                "category": String(category.prefix(50)),
                "level": String(level.prefix(20)),
                "message": String(message.prefix(500)),
                "data": Self.boundedAttributes(data)
            ])
            if self.breadcrumbs.count > 50 {
                self.breadcrumbs.removeFirst(self.breadcrumbs.count - 50)
            }
        }
    }

    /// Sets an explicit event tag included with later errors and messages.
    public func setTag(_ key: String, value: String?) {
        guard enabledValue else { return }
        stateQueue.async { [weak self] in
            guard let self, !self.disposing, !self.disposed else { return }
            let key = String(key.prefix(200))
            if let value {
                if self.tags.count < 50 || self.tags[key] != nil {
                    self.tags[key] = String(value.prefix(300))
                }
            } else {
                self.tags.removeValue(forKey: key)
            }
        }
    }

    /// Sets an explicit context included with later errors and messages.
    public func setContext(_ values: [String: String]?, for name: String) {
        guard enabledValue else { return }
        stateQueue.async { [weak self] in
            guard let self, !self.disposing, !self.disposed else { return }
            let name = String(name.prefix(200))
            if let values {
                if self.contexts.count < 20 || self.contexts[name] != nil {
                    self.contexts[name] = Self.boundedAttributes(values)
                }
            } else {
                self.contexts.removeValue(forKey: name)
            }
        }
    }

    /// Starts a manual span, optionally as a child of another span.
    public func startSpan(_ name: String, operation: String = "", parent: TraceSpan? = nil, segment: Bool? = nil) -> TraceSpan? {
        guard enabledValue else { return nil }
        let rate = min(max(options.tracesSampleRate, 0), 1)
        let sampled = parent.map(\.sampled) ?? (rate >= 1 || (rate > 0 && Double.random(in: 0..<1) < rate))
        let span = TraceSpan(
            client: self,
            traceID: parent?.traceID ?? Self.randomID(bytes: 16),
            spanID: Self.randomID(bytes: 8),
            parentID: parent?.spanID,
            sampled: sampled,
            isSegment: segment ?? (parent == nil),
            name: name,
            operation: operation
        )
        return span
    }

    /// Starts a segment from a W3C `traceparent`. Invalid or absent values start a new trace.
    public func continueTrace(traceparent: String?, name: String, operation: String = "") -> TraceSpan? {
        guard enabledValue else { return nil }
        if let parent = Self.parseTraceparent(traceparent) {
            let rate = min(max(options.tracesSampleRate, 0), 1)
            return TraceSpan(
                client: self,
                traceID: parent.traceID,
                spanID: Self.randomID(bytes: 8),
                parentID: parent.spanID,
                sampled: parent.sampled && rate > 0,
                isSegment: true,
                name: name,
                operation: operation
            )
        }
        return startSpan(name, operation: operation, segment: true)
    }

    /// Hashes a user id using the same explicit, one-way scheme as the JS SDK. No user id is collected automatically.
    public static func userHash(for userID: String) -> String {
        let digest = SHA256.hash(data: Data(("delg-user:" + userID).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Sends queued batches asynchronously. Completion runs on the main queue; false means the deadline elapsed or delivery needs a later retry.
    @objc(flushWithTimeout:completion:)
    public func flush(timeout: TimeInterval = 5, completion: @escaping (Bool) -> Void) {
        guard enabledValue else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.disposed {
                self.deliver(completion, result: self.records.isEmpty)
                return
            }
            self.addWaiter(timeout: timeout, dispose: false, completion: completion)
            self.pump()
        }
    }

    /// Swift async variant of bounded flush.
    public func flush(timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            flush(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// Stops accepting new events and waits up to `timeout` for the queue to drain.
    /// Unsent events stay on disk for the next client instance.
    @objc(disposeWithTimeout:completion:)
    public func dispose(timeout: TimeInterval = 5, completion: @escaping (Bool) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.disposed {
                self.deliver(completion, result: self.records.isEmpty)
                return
            }
            self.disposing = true
            self.addWaiter(timeout: timeout, dispose: true, completion: completion)
            self.pump()
        }
    }

    /// Swift async variant of bounded disposal.
    public func dispose(timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            dispose(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    func enqueue(_ event: [String: Any]) {
        guard enabledValue else { return }
        enqueueWithState(event)
    }

    private func enqueueWithState(_ event: [String: Any]) {
        stateQueue.async { [weak self] in
            guard let self, !self.disposing, !self.disposed else { return }
            var event = event
            if event["type"] as? String == "error" {
                if !self.breadcrumbs.isEmpty { event["breadcrumbs"] = self.breadcrumbs }
                var mergedTags = self.tags
                for (key, value) in (event["tags"] as? [String: String] ?? [:]) { mergedTags[key] = value }
                if !mergedTags.isEmpty { event["tags"] = Self.boundedAttributes(mergedTags) }
                var mergedContexts = self.contexts
                for (key, value) in (event["contexts"] as? [String: [String: String]] ?? [:]) { mergedContexts[key] = Self.boundedAttributes(value) }
                if !mergedContexts.isEmpty { event["contexts"] = Self.boundedContexts(mergedContexts) }
            }
            guard self.applyBeforeSend(&event),
                  let type = event["type"] as? String,
                  ["error", "span", "log"].contains(type),
                  JSONSerialization.isValidJSONObject(event),
                  let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
                  data.count <= Self.maxEventBytes,
                  self.records.count < Self.maxQueueEvents,
                  self.queueBytes + data.count <= Self.maxQueueBytes else { return }

            let header = IngestHeader(
                sdk: Self.sdkVersion,
                release: String(self.options.release.prefix(100)),
                environment: String(self.options.environment.prefix(50)),
                server: String(self.options.server.prefix(100))
            )
            let endpoint = self.configuredIngestURL
            self.records.append(QueuedEvent(event: data, header: header, endpoint: endpoint))
            self.queueBytes += data.count
            self.persistQueue()
            if self.records.count >= Self.maxBatchEvents {
                self.pump()
            } else if self.options.automaticFlushInterval <= 0 {
                // Explicit-flush mode never starts a background timer.
            } else if !self.sending {
                self.schedulePump(after: self.options.automaticFlushInterval)
            }
        }
    }

    private func errorEvent(
        level: String,
        extraTags: [String: String],
        extraContexts: [String: [String: String]],
        span: TraceSpan?,
        userHash: String?,
        fingerprint: [String]?
    ) -> [String: Any] {
        var event: [String: Any] = [
            "type": "error",
            "event_id": Self.randomID(bytes: 16),
            "ts": Self.timestamp(),
            "level": Self.normalizedErrorLevel(level)
        ]
        if !extraTags.isEmpty { event["tags"] = Self.boundedAttributes(extraTags) }
        if !extraContexts.isEmpty { event["contexts"] = Self.boundedContexts(extraContexts) }
        if let span {
            event["trace_id"] = span.traceID
            event["span_id"] = span.spanID
        }
        if let userHash, Self.isValidUserHash(userHash) { event["user_hash"] = userHash.lowercased() }
        if let fingerprint, !fingerprint.isEmpty { event["fingerprint"] = Array(fingerprint.prefix(10)).map { String($0.prefix(200)) } }
        return event
    }

    private func applyBeforeSend(_ event: inout [String: Any]) -> Bool {
        guard let beforeSend = options.beforeSend else { return true }
        return beforeSend(&event)
    }

    private static func ingestURL(for baseEndpoint: String) -> String {
        String(baseEndpoint.prefix(2_000)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/ingest/v1/events"
    }

    private func addWaiter(timeout: TimeInterval, dispose: Bool, completion: @escaping (Bool) -> Void) {
        let id = UUID()
        flushWaiters.append(FlushWaiter(id: id, dispose: dispose, completion: completion))
        stateQueue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
            guard let self, let index = self.flushWaiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = self.flushWaiters.remove(at: index)
            if waiter.dispose { self.finishDisposal() }
            self.deliver(waiter.completion, result: false)
        }
    }

    private func pump() {
        guard enabledValue, !disposed, !sending else { return }
        guard !records.isEmpty else {
            finishWaitersIfDrained()
            return
        }
        let pause = pausedUntil.timeIntervalSinceNow
        if pause > 0 {
            schedulePump(after: pause)
            return
        }
        guard let batch = makeBatch() else {
            // A malformed or individually oversized persisted row cannot block later rows.
            removeRecords(count: 1)
            pump()
            return
        }
        sending = true
        send(batch, attempt: 0)
    }

    private func makeBatch() -> Batch? {
        guard let first = records.first,
              Self.isValidIngestURL(first.endpoint),
              let url = URL(string: first.endpoint),
              let headerData = try? encoder.encode(first.header) else { return nil }
        var body = headerData
        var count = 0
        for record in records {
            guard record.header == first.header, record.endpoint == first.endpoint, count < Self.maxBatchEvents else { break }
            let additional = 1 + record.event.count
            guard body.count + additional <= Self.maxBodyBytes else { break }
            body.append(contentsOf: [10])
            body.append(record.event)
            count += 1
        }
        guard count > 0 else { return nil }
        return Batch(count: count, url: url, body: body)
    }

    private func send(_ batch: Batch, attempt: Int) {
        var request = URLRequest(url: batch.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(options.token, forHTTPHeaderField: "X-Trace-Token")
        request.httpBody = batch.body

        let task = transportSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.stateQueue.async {
                self.activeTask = nil
                guard self.sending else { return }
                let status = (response as? HTTPURLResponse)?.statusCode
                if status == 429 {
                    let wait = Self.retryAfter((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))
                    self.pausedUntil = Date().addingTimeInterval(wait)
                    self.sending = false
                    self.schedulePump(after: wait)
                    self.finishWaitersIfDrained()
                    return
                }
                if error != nil || status == nil || status! >= 500 {
                    if self.disposed {
                        self.sending = false
                        return
                    }
                    if attempt < 2 {
                        let delay = Double((attempt + 1) * (attempt + 1))
                        self.stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, !self.disposed else { return }
                            self.send(batch, attempt: attempt + 1)
                        }
                        return
                    }
                    self.sending = false
                    self.pausedUntil = Date().addingTimeInterval(30)
                    self.resolveWaiters(result: false)
                    self.schedulePump(after: 30)
                    return
                }

                // 2xx is accepted; 4xx other than 429 is a permanent refusal and must not loop.
                self.removeRecords(count: batch.count)
                self.sending = false
                self.pump()
            }
        }
        activeTask = task
        task.resume()
    }

    private func schedulePump(after delay: TimeInterval) {
        scheduledPump?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledPump = nil
            self.pump()
        }
        scheduledPump = work
        stateQueue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func removeRecords(count: Int) {
        let amount = min(max(count, 0), records.count)
        if amount > 0 {
            queueBytes -= records.prefix(amount).reduce(0) { $0 + $1.event.count }
            records.removeFirst(amount)
            persistQueue()
        }
    }

    private func finishWaitersIfDrained() {
        guard records.isEmpty, !sending else { return }
        resolveWaiters(result: true)
    }

    private func resolveWaiters(result: Bool) {
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters {
            if waiter.dispose { finishDisposal() }
            deliver(waiter.completion, result: result)
        }
    }

    private func finishDisposal() {
        disposing = true
        disposed = true
        scheduledPump?.cancel()
        scheduledPump = nil
        activeTask?.cancel()
        activeTask = nil
        sending = false
        timer?.cancel()
        timer = nil
    }

    private func deliver(_ completion: @escaping (Bool) -> Void, result: Bool) {
        DispatchQueue.main.async { completion(result) }
    }

    private func persistQueue() {
        guard let queueURL else { return }
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: queueURL)
            return
        }
        guard let data = try? encoder.encode(records) else { return }
        do {
            try data.write(to: queueURL, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = queueURL
            try? mutableURL.setResourceValues(values)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: queueURL.path)
            #endif
        } catch {
            // Keep the in-memory queue usable when storage is temporarily unavailable.
        }
    }

    private static func makeQueueURL(options: TraceOptions, ingestURL: String) -> URL? {
        guard !options.token.isEmpty, isValidIngestURL(ingestURL) else { return nil }
        let base: URL
        if let configured = options.storageDirectory {
            base = configured
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = support.appendingPathComponent("DELGTrace", isDirectory: true)
        } else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableBase = base
            try? mutableBase.setResourceValues(values)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: base.path)
            #endif
        } catch {
            return nil
        }
        let queueIdentity = options.token + "\0" + ingestURL
        let digest = SHA256.hash(data: Data(queueIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("queue-\(digest).json", isDirectory: false)
    }

    private static func isValidIngestURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return false }
        return true
    }

    private static func loadQueue(at url: URL, expectedEndpoint: String) -> [QueuedEvent] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue <= 16 * 1_024 * 1_024,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([QueuedEvent].self, from: data) else { return [] }
        var accepted: [QueuedEvent] = []
        var bytes = 0
        for record in decoded {
            guard record.endpoint == expectedEndpoint,
                  isValidIngestURL(record.endpoint),
                  accepted.count < maxQueueEvents,
                  record.event.count <= maxEventBytes,
                  bytes + record.event.count <= maxQueueBytes,
                  let object = try? JSONSerialization.jsonObject(with: record.event),
                  let json = object as? [String: Any],
                  ["error", "span", "log"].contains(json["type"] as? String ?? "") else { continue }
            accepted.append(record)
            bytes += record.event.count
        }
        return accepted
    }

    private static func timestamp() -> Double { Date().timeIntervalSince1970 * 1_000 }

    private static func randomID(bytes: Int) -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(bytes * 2))
    }

    private static func boundedAttributes(_ values: [String: String]) -> [String: String] {
        Dictionary(values.prefix(50).map { (String($0.key.prefix(200)), String($0.value.prefix(300))) }, uniquingKeysWith: { first, _ in first })
    }

    private static func boundedContexts(_ values: [String: [String: String]]) -> [String: [String: String]] {
        Dictionary(values.prefix(20).map { (String($0.key.prefix(200)), boundedAttributes($0.value)) }, uniquingKeysWith: { first, _ in first })
    }

    private static func normalizedErrorLevel(_ value: String) -> String {
        let level = value.lowercased()
        if level == "warn" { return "warning" }
        return ["fatal", "error", "warning", "info", "debug"].contains(level) ? level : "error"
    }

    private static func normalizedLogLevel(_ value: String) -> String {
        let level = value.lowercased()
        if level == "warning" { return "warn" }
        return ["trace", "debug", "info", "warn", "error", "fatal"].contains(level) ? level : "info"
    }

    private static func retryAfter(_ value: String?) -> TimeInterval {
        guard let value, let seconds = TimeInterval(value) else { return 1 }
        return min(max(seconds, 1), 60)
    }

    private static func isValidUserHash(_ value: String) -> Bool {
        let lower = value.lowercased()
        return (16...64).contains(lower.count) && lower.allSatisfy { $0.isHexDigit }
    }

    private static func exceptionPayloads(for error: Error, frames: [[String: Any]]) -> [[String: Any]] {
        var output: [[String: Any]] = []
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        while let value = current, output.count < 10, seen.insert(ObjectIdentifier(value)).inserted {
            let exceptionType = value.domain.isEmpty ? String(reflecting: type(of: error)) : value.domain
            var exception: [String: Any] = [
                "type": String(exceptionType.prefix(200)),
                "value": String(value.localizedDescription.prefix(2_000))
            ]
            if output.isEmpty && !frames.isEmpty { exception["frames"] = frames }
            output.append(exception)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return output
    }

    private static func callSiteFrames(inAppImagePrefixes: [String]) -> [[String: Any]] {
        // Capture before dispatching to the transport queue so this is the caller's stack.
        Thread.callStackSymbols.dropFirst(2).prefix(100).compactMap {
            parseCallStackSymbol($0, inAppImagePrefixes: inAppImagePrefixes)
        }
    }

    static func parseCallStackSymbol(_ line: String, inAppImagePrefixes: [String]) -> [String: Any]? {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 4,
              Int(parts[0]) != nil,
              let addressIndex = parts.firstIndex(where: isLoadAddress),
              addressIndex >= 2,
              addressIndex + 1 < parts.count else { return nil }

        var functionParts = Array(parts.dropFirst(addressIndex + 1))
        if functionParts.count >= 2,
           functionParts[functionParts.count - 2] == "+",
           Int(functionParts[functionParts.count - 1]) != nil {
            functionParts.removeLast(2)
        }
        guard !functionParts.isEmpty,
              !functionParts.contains(where: isLoadAddress),
              !functionParts[0].hasPrefix("<") else { return nil }

        let imageName = parts[addressIndex - 1]
        let function = String(functionParts.joined(separator: " ").prefix(300))
        let isInApp = inAppImagePrefixes.contains { !$0.isEmpty && imageName.hasPrefix($0) }
        return ["fn": function, "in_app": isInApp]
    }

    private static func isLoadAddress(_ part: String) -> Bool {
        guard part.hasPrefix("0x"), part.count > 2 else { return false }
        return part.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    static func parseTraceparent(_ header: String?) -> (traceID: String, spanID: String, sampled: Bool)? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 4,
              parts[0].count == 2,
              isLowercaseHex(parts[0]),
              parts[0] != "ff",
              parts[1].count == 32,
              isLowercaseHex(parts[1]),
              parts[1].contains(where: { $0 != "0" }),
              parts[2].count == 16,
              isLowercaseHex(parts[2]),
              parts[2].contains(where: { $0 != "0" }),
              parts[3].count == 2,
              isLowercaseHex(parts[3]) else { return nil }

        if parts[0] == "00" {
            guard parts.count == 4 else { return nil }
        } else {
            // Future versions may append fields. This client only reads the v00 fields.
            guard parts.dropFirst(4).allSatisfy({ !$0.isEmpty }) else { return nil }
        }
        return (String(parts[1]), String(parts[2]), (UInt8(String(parts[3]), radix: 16) ?? 0) & 1 == 1)
    }

    private static func isLowercaseHex<S: StringProtocol>(_ value: S) -> Bool {
        value.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    }
}

private final class RedirectBlockingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct IngestHeader: Codable, Equatable {
    let sdk: String
    let release: String
    let environment: String
    let server: String
}

private struct QueuedEvent: Codable {
    let event: Data
    let header: IngestHeader
    let endpoint: String
}

private struct Batch {
    let count: Int
    let url: URL
    let body: Data
}

private struct FlushWaiter {
    let id: UUID
    let dispose: Bool
    let completion: (Bool) -> Void
}
