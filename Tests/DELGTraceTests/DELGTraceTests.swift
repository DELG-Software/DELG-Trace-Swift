import Foundation
import CryptoKit
import XCTest
@testable import DELGTrace

final class DELGTraceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset { _ in (202, [:], nil) }
    }

    override func tearDown() {
        StubURLProtocol.reset { _ in (202, [:], nil) }
        super.tearDown()
    }

    func testSerializationRedactionAndManualSpan() async throws {
        let directory = try temporaryDirectory()
        let client = TraceClient(options: options(
            directory: directory,
            release: "build-abc",
            environment: "staging",
            server: "ios-worker",
            tracesSampleRate: 1,
            beforeSend: { event in
                if event["message"] as? String == "private message" {
                    event["message"] = "[redacted]"
                }
                if event["type"] as? String == "log" { event["body"] = "[redacted log]" }
                if event["type"] as? String == "span" { event["attrs"] = ["safe": "yes"] }
                return true
            }
        ))

        client.addBreadcrumb(category: "ui", message: "Tapped Save", data: ["screen": "settings"])
        client.setTag("feature", value: "profile")
        client.setContext(["attempt": "2"], for: "retry")
        client.captureMessage("private message", level: "warning", tags: ["local": "yes"])
        client.capture(error: SampleError(), tags: ["source": "manual"])
        let span = try XCTUnwrap(client.startSpan("load profile", operation: "db"))
        span.setAttribute("db.system", value: "sqlite")
        span.end()
        client.log("info", body: "private log")

        let flushed = await client.flush(timeout: 3)
        XCTAssertTrue(flushed)
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/trace/ingest/v1/events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace-Token"), "trc_swift_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")

        let body = try XCTUnwrap(request.httpBody)
        XCTAssertLessThan(body.count, 1_048_576)
        let lines = try XCTUnwrap(String(data: body, encoding: .utf8)).split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        XCTAssertEqual(header["sdk"], "swift/0.2.0")
        XCTAssertEqual(header["release"], "build-abc")
        XCTAssertEqual(header["environment"], "staging")
        XCTAssertEqual(header["server"], "ios-worker")

        let message = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "error")
        XCTAssertEqual(message["message"] as? String, "[redacted]")
        XCTAssertEqual(message["level"] as? String, "warning")
        XCTAssertGreaterThan(message["ts"] as? Double ?? 0, 1_000_000_000_000)
        XCTAssertEqual((message["tags"] as? [String: String])?["feature"], "profile")
        XCTAssertEqual((message["tags"] as? [String: String])?["local"], "yes")
        XCTAssertEqual((message["contexts"] as? [String: [String: String]])?["retry"]?["attempt"], "2")
        let crumbs = try XCTUnwrap(message["breadcrumbs"] as? [[String: Any]])
        XCTAssertEqual(crumbs.first?["message"] as? String, "Tapped Save")

        let errorEvent = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any])
        let exceptions = try XCTUnwrap(errorEvent["exceptions"] as? [[String: Any]])
        XCTAssertEqual(exceptions.first?["value"] as? String, "sample swift error")
        XCTAssertFalse((exceptions.first?["frames"] as? [[String: Any]] ?? []).isEmpty)

        let spanEvent = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[3].utf8)) as? [String: Any])
        XCTAssertEqual(spanEvent["type"] as? String, "span")
        XCTAssertEqual(spanEvent["name"] as? String, "load profile")
        XCTAssertEqual(spanEvent["op"] as? String, "db")
        XCTAssertEqual(spanEvent["trace_id"] as? String, span.traceID)
        XCTAssertEqual((spanEvent["attrs"] as? [String: String])?["safe"], "yes")
        XCTAssertTrue(span.isSegment)
        XCTAssertEqual(span.traceparent.count, 55)
        let logEvent = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[4].utf8)) as? [String: Any])
        XCTAssertEqual(logEvent["body"] as? String, "[redacted log]")
        let disposed = await client.dispose(timeout: 1)
        XCTAssertTrue(disposed)
    }

    func testExplicitSessionLifecycleDebugFramesAndThrowingDiagnostics() async throws {
        let directory = try temporaryDirectory()
        let client = TraceClient(options: TraceOptions(
            token: "trc_swift_test", endpoint: "https://unit.test/trace", storageDirectory: directory,
            session: makeSession(), automaticFlushInterval: 0,
            onDiagnostic: { _ in throw SampleError() }
        ))
        let firstSID = try XCTUnwrap(client.startSession())
        XCTAssertEqual(client.startSession(), firstSID)
        XCTAssertTrue(client.updateSession())
        XCTAssertEqual(StubURLProtocol.requests.count, 0, "a clean, active session must not be marked crash-free")

        client.captureMessage("fatal state", level: "fatal")
        client.capture(error: SampleError(), frames: [TraceFrame(
            function: "submitOrder", module: "Checkout", debugID: "A1B2", instructionAddress: "0x10001234",
            imageAddress: "0x10000000", architecture: "arm64", buildID: "build-7"
        )])
        XCTAssertTrue(client.endSession())
        XCTAssertFalse(client.endSession())
        let secondSID = try XCTUnwrap(client.startSession())
        XCTAssertNotEqual(firstSID, secondSID)
        XCTAssertTrue(client.endSession())
        let flushResult = await client.flush(timeout: 3)
        XCTAssertTrue(flushResult)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let rows = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)).split(separator: "\n")
        let items = try rows.dropFirst().map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let sessions = items.filter { $0["type"] as? String == "session" }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map { $0["status"] as? String }, ["errored", "ok"])
        XCTAssertEqual(sessions.first?["sid"] as? String, firstSID)
        XCTAssertEqual(sessions.last?["sid"] as? String, secondSID)
        let error = try XCTUnwrap(items.first { $0["type"] as? String == "error" && $0["exceptions"] != nil })
        let frame = try XCTUnwrap((error["exceptions"] as? [[String: Any]])?.first?["frames"] as? [[String: Any]])
        XCTAssertEqual(frame.first?["debug_id"] as? String, "A1B2")
        XCTAssertEqual(frame.first?["instruction_addr"] as? String, "0x10001234")
        XCTAssertGreaterThan(client.diagnosticsSnapshot().callbackFailures, 0)
        XCTAssertEqual(client.diagnosticsSnapshot().queueSize, 0)
        let disposeResult = await client.dispose(timeout: 1)
        XCTAssertTrue(disposeResult)
    }

    func testSuccessfulResponseCountsRequireACompleteBatchBreakdown() async throws {
        for (body, expectedAccepted, expectedRejected, expectedDropped) in [
            ("{\"accepted\":1,\"dropped\":1}", UInt64(1), UInt64(1), UInt64(1)),
            ("{\"accepted\":1,\"dropped\":0}", UInt64(2), UInt64(0), UInt64(0)),
            ("{\"accepted\":-1,\"dropped\":3}", UInt64(2), UInt64(0), UInt64(0))
        ] {
            let directory = try temporaryDirectory()
            StubURLProtocol.setResponseBody(Data(body.utf8))
            let client = TraceClient(options: options(directory: directory))
            client.captureMessage("first")
            client.captureMessage("second")
            let flushed = await client.flush(timeout: 3)
            XCTAssertTrue(flushed)
            let diagnostics = client.diagnosticsSnapshot()
            XCTAssertEqual(diagnostics.accepted, expectedAccepted)
            XCTAssertEqual(diagnostics.rejected, expectedRejected)
            XCTAssertEqual(diagnostics.dropped, expectedDropped)
            let disposed = await client.dispose(timeout: 1)
            XCTAssertTrue(disposed)
        }
    }

    func testDisabledClientDoesNotWriteOrSend() async throws {
        let directory = try temporaryDirectory()
        let client = TraceClient(options: TraceOptions(
            storageDirectory: directory,
            session: makeSession(),
            automaticFlushInterval: 0
        ))

        XCTAssertFalse(client.isEnabled)
        client.captureMessage("ignored")
        client.capture(error: NSError(domain: "test", code: 1))
        client.log("info", body: "ignored")
        let flushed = await client.flush(timeout: 1)
        XCTAssertTrue(flushed)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testInvalidEndpointDisablesCaptureAndStorage() async throws {
        let directory = try temporaryDirectory()
        let client = TraceClient(options: TraceOptions(
            token: "trc_swift_test",
            endpoint: "file:///tmp/trace",
            storageDirectory: directory,
            session: makeSession(),
            automaticFlushInterval: 0
        ))

        XCTAssertFalse(client.isEnabled)
        client.captureMessage("must not be sent")
        let flushed = await client.flush(timeout: 1)
        XCTAssertTrue(flushed)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testTwoArgumentCaptureMessageUsesSwiftOverload() async throws {
        let directory = try temporaryDirectory()
        let client = TraceClient(options: options(directory: directory))
        client.captureMessage("simple Swift call", level: "warning")

        let flushed = await client.flush(timeout: 1)
        XCTAssertTrue(flushed)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let lines = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8)).split(separator: "\n")
        let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(event["message"] as? String, "simple Swift call")
        XCTAssertEqual(event["level"] as? String, "warning")
    }

    func test429HonorsRetryAfterAndRetainsLaterEvents() async throws {
        let directory = try temporaryDirectory()
        StubURLProtocol.reset { _ in (429, ["Retry-After": "1"], nil) }
        let client = TraceClient(options: options(directory: directory))

        client.captureMessage("quota event")
        let firstFlush = await client.flush(timeout: 0.1)
        XCTAssertFalse(firstFlush)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let originalBody = try XCTUnwrap(StubURLProtocol.requests.first?.httpBody)
        let originalLines = try XCTUnwrap(String(data: originalBody, encoding: .utf8)).split(separator: "\n")
        XCTAssertEqual(originalLines.count, 2)

        client.captureMessage("queued while paused")
        let pausedFlush = await client.flush(timeout: 0.1)
        XCTAssertFalse(pausedFlush)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("queue-") })

        StubURLProtocol.setHandler { _ in (202, [:], nil) }
        let resumedFlush = await client.flush(timeout: 3)
        XCTAssertTrue(resumedFlush)
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        let retriedBody = try XCTUnwrap(requests[1].httpBody)
        let retriedLines = try XCTUnwrap(String(data: retriedBody, encoding: .utf8)).split(separator: "\n")
        XCTAssertEqual(retriedLines.count, 3)
        XCTAssertEqual(retriedLines[1], originalLines[1])
        let laterEvent = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(retriedLines[2].utf8)) as? [String: Any])
        XCTAssertEqual(laterEvent["message"] as? String, "queued while paused")

        let disposed = await client.dispose(timeout: 1)
        XCTAssertTrue(disposed)
    }

    func testRedirectRetainsEventWithoutForwardingTraceToken() async throws {
        let directory = try temporaryDirectory()
        StubURLProtocol.reset { _ in (307, ["Location": "https://attacker.test/collect"], nil) }
        let client = TraceClient(options: options(directory: directory))

        client.captureMessage("redirect check")
        let flushed = await client.flush(timeout: 1)

        XCTAssertFalse(flushed)
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.host, "unit.test")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Trace-Token"), "trc_swift_test")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("queue-") })
        let disposed = await client.dispose(timeout: 1)
        XCTAssertFalse(disposed)
    }

    func testRetriesAreBoundedAndOfflineQueueSurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        StubURLProtocol.reset { _ in (503, [:], nil) }
        let offline = TraceClient(options: options(directory: directory, release: "offline-build"))
        offline.captureMessage("kept for later")

        let offlineFlush = await offline.flush(timeout: 8)
        XCTAssertFalse(offlineFlush)
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("queue-") })
        let offlineDisposed = await offline.dispose(timeout: 0.05)
        XCTAssertFalse(offlineDisposed)

        StubURLProtocol.reset { _ in (202, [:], nil) }
        let online = TraceClient(options: options(directory: directory, release: "new-build"))
        let onlineFlush = await online.flush(timeout: 3)
        XCTAssertTrue(onlineFlush)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let lines = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8)).split(separator: "\n")
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        XCTAssertEqual(header["release"], "offline-build")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let onlineDisposed = await online.dispose(timeout: 1)
        XCTAssertTrue(onlineDisposed)
    }

    func testUserHashMatchesSharedSDKContract() {
        XCTAssertEqual(TraceClient.userHash(for: "user-1"), "77bf4899e8adf5421c20d18dc35945c1")
    }

    func testCallStackFramesUseStableSymbolsAndExplicitInAppImagePrefixes() throws {
        let symbol = "_$s8Checkout12submitOrderyyF"
        let line = "3 Checkout 0x0000000101234567 \(symbol) + 48"
        let frame = try XCTUnwrap(TraceClient.parseCallStackSymbol(line, inAppImagePrefixes: ["Checkout"]))

        XCTAssertEqual(frame["fn"] as? String, symbol)
        XCTAssertEqual(frame["in_app"] as? Bool, true)
        XCTAssertFalse((frame["fn"] as? String ?? "").contains("0x"))
        XCTAssertNil(TraceClient.parseCallStackSymbol("4 Checkout 0x0000000101234567 0x0000000101234000 + 8", inAppImagePrefixes: []))

        let external = try XCTUnwrap(TraceClient.parseCallStackSymbol("5 Foundation 0x0000000101234567 _dispatch_call_block_and_release + 12", inAppImagePrefixes: ["Checkout"]))
        XCTAssertEqual(external["in_app"] as? Bool, false)
    }

    func testTraceparentRejectsInvalidW3CIdentifiersAndVersion() throws {
        let traceID = "0af7651916cd43dd8448eb211c80319c"
        let spanID = "b7ad6b7169203331"
        XCTAssertNotNil(TraceClient.parseTraceparent("00-\(traceID)-\(spanID)-01"))
        XCTAssertNil(TraceClient.parseTraceparent("00-00000000000000000000000000000000-\(spanID)-01"))
        XCTAssertNil(TraceClient.parseTraceparent("00-\(traceID)-0000000000000000-01"))
        XCTAssertNil(TraceClient.parseTraceparent("ff-\(traceID)-\(spanID)-01"))
        XCTAssertNil(TraceClient.parseTraceparent("00-\(traceID)-\(spanID)-01-extra"))
        XCTAssertNil(TraceClient.parseTraceparent("00-0AF7651916CD43DD8448EB211C80319C-\(spanID)-01"))
        XCTAssertNotNil(TraceClient.parseTraceparent("01-\(traceID)-\(spanID)-01-extension"))
    }

    func testPersistedQueueCannotRedirectOrCrossEndpoints() async throws {
        let directory = try temporaryDirectory()
        let token = "trc_swift_test"
        let configuredEndpoint = "https://unit.test/trace"
        let attackerEndpoint = "https://attacker.test/trace"
        try seedQueue(directory: directory, token: token, baseEndpoint: configuredEndpoint, storedEndpoint: "\(attackerEndpoint)/ingest/v1/events")

        let client = TraceClient(options: options(directory: directory, endpoint: configuredEndpoint))
        let redirectedFlush = await client.flush(timeout: 1)
        XCTAssertTrue(redirectedFlush)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let redirectedDispose = await client.dispose(timeout: 1)
        XCTAssertTrue(redirectedDispose)

        let firstEndpoint = "https://first.test/trace"
        let secondEndpoint = "https://second.test/trace"
        try seedQueue(directory: directory, token: token, baseEndpoint: firstEndpoint, storedEndpoint: "\(firstEndpoint)/ingest/v1/events")
        let secondClient = TraceClient(options: options(directory: directory, endpoint: secondEndpoint))
        let isolatedFlush = await secondClient.flush(timeout: 1)
        XCTAssertTrue(isolatedFlush)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("queue-") }.count, 1)
        let isolatedDispose = await secondClient.dispose(timeout: 1)
        XCTAssertTrue(isolatedDispose)
    }

    func testTimedOutDisposalStopsScheduledRetries() async throws {
        let directory = try temporaryDirectory()
        StubURLProtocol.reset { _ in (503, [:], nil) }
        let client = TraceClient(options: options(directory: directory))
        client.captureMessage("retain after dispose timeout")

        let flushTask = Task { await client.flush(timeout: 0.2) }
        let disposed = await client.dispose(timeout: 0.05)
        XCTAssertFalse(disposed)
        let flushResult = await flushTask.value
        XCTAssertFalse(flushResult)

        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testTimedOutDisposalCancelsInFlightRequestAndKeepsQueue() async throws {
        let directory = try temporaryDirectory()
        let stopped = expectation(description: "URLSession request was cancelled")
        BlockingURLProtocol.reset { stopped.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = TraceClient(options: TraceOptions(
            token: "trc_swift_test",
            endpoint: "https://unit.test/trace",
            storageDirectory: directory,
            session: session,
            automaticFlushInterval: 0
        ))
        client.captureMessage("retain after cancellation")

        let disposed = await client.dispose(timeout: 0.05)
        XCTAssertFalse(disposed)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(BlockingURLProtocol.requestsStarted, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("queue-") })
    }

    #if canImport(ObjectiveC)
    func testObjectiveCSelectorsAreUnambiguous() {
        XCTAssertEqual(NSStringFromSelector(#selector(TraceClient.init(token:release:environment:endpoint:))), "initWithToken:release:environment:endpoint:")
        XCTAssertEqual(NSStringFromSelector(#selector(TraceClient.captureError(_:))), "captureError:")
        XCTAssertEqual(NSStringFromSelector(#selector(TraceClient.captureMessageForObjectiveC(_:level:))), "captureMessage:level:")
        XCTAssertEqual(NSStringFromSelector(#selector(TraceClient.flush(timeout:completion:))), "flushWithTimeout:completion:")
        XCTAssertEqual(NSStringFromSelector(#selector(TraceClient.dispose(timeout:completion:))), "disposeWithTimeout:completion:")
    }
    #endif

    private func options(
        directory: URL,
        endpoint: String = "https://unit.test/trace",
        release: String = "test-release",
        environment: String = "test",
        server: String = "",
        tracesSampleRate: Double = 0,
        beforeSend: TraceOptions.BeforeSend? = nil
    ) -> TraceOptions {
        TraceOptions(
            token: "trc_swift_test",
            endpoint: endpoint,
            release: release,
            environment: environment,
            server: server,
            tracesSampleRate: tracesSampleRate,
            storageDirectory: directory,
            session: makeSession(),
            automaticFlushInterval: 0,
            beforeSend: beforeSend
        )
    }

    private func seedQueue(directory: URL, token: String, baseEndpoint: String, storedEndpoint: String) throws {
        let ingestURL = baseEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/ingest/v1/events"
        let identity = token + "\0" + ingestURL
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let queueURL = directory.appendingPathComponent("queue-\(digest).json")
        let event = try JSONSerialization.data(withJSONObject: ["type": "error", "event_id": "00000000000000000000000000000001"])
        let record: [String: Any] = [
            "event": event.base64EncodedString(),
            "header": ["sdk": "swift/0.1.0", "release": "old", "environment": "test", "server": ""],
            "endpoint": storedEndpoint
        ]
        try JSONSerialization.data(withJSONObject: [record]).write(to: queueURL, options: .atomic)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DELGTraceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct SampleError: LocalizedError {
    var errorDescription: String? { "sample swift error" }
}

private final class StubURLProtocol: URLProtocol {
    typealias Stub = (Int, [String: String], Error?)
    private static let lock = NSLock()
    private static var stub: (URLRequest) -> Stub = { _ in (202, [:], nil) }
    private static var recordedRequests: [URLRequest] = []
    private static var responseBody = Data()

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func reset(_ response: @escaping (URLRequest) -> Stub) {
        lock.lock()
        stub = response
        recordedRequests = []
        responseBody = Data()
        lock.unlock()
    }

    static func setHandler(_ response: @escaping (URLRequest) -> Stub) {
        lock.lock()
        stub = response
        lock.unlock()
    }

    static func setResponseBody(_ data: Data) {
        lock.lock()
        responseBody = data
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func requestWithReadableBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                stream.read(bytes.baseAddress!, maxLength: bytes.count)
            }
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }

        var captured = request
        captured.httpBody = body
        captured.httpBodyStream = nil
        return captured
    }

    override func startLoading() {
        let capturedRequest = Self.requestWithReadableBody(task?.originalRequest ?? request)
        Self.lock.lock()
        Self.recordedRequests.append(capturedRequest)
        let handler = Self.stub
        let responseBody = Self.responseBody
        Self.lock.unlock()
        let (status, headers, error) = handler(capturedRequest)
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if (300..<400).contains(status),
           let location = headers.first(where: { $0.key.caseInsensitiveCompare("Location") == .orderedSame })?.value,
           let redirectedURL = URL(string: location, relativeTo: url)?.absoluteURL {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectedURL), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BlockingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var startCount = 0
    private static var onStop: (() -> Void)?

    static var requestsStarted: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCount
    }

    static func reset(onStop: @escaping () -> Void) {
        lock.lock()
        startCount = 0
        self.onStop = onStop
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.startCount += 1
        Self.lock.unlock()
    }

    override func stopLoading() {
        Self.lock.lock()
        let handler = Self.onStop
        Self.onStop = nil
        Self.lock.unlock()
        handler?()
    }
}
