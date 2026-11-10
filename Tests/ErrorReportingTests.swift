//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  ErrorReportingTests.swift
//  Starscream
//
//  Smoke tests for the write error reporting API (write(..., reportingError:)).
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import XCTest
@testable import Starscream

class ErrorReportingTests: XCTestCase {

    // The pre-existing completion-based call sites must keep compiling unchanged.
    func testLegacyCompletionCallsStillCompile() {
        if #available(macOS 10.15, iOS 13.0, *) {
            let socket = WebSocket(request: URLRequest(url: URL(string: "ws://localhost:0")!), useCustomEngine: false)
            socket.write(string: "hello")
            socket.write(string: "hello", completion: nil)
            socket.write(data: Data([1]), completion: {})
            socket.write(ping: Data(), completion: nil)
            socket.write(pong: Data(), completion: {})
            socket.write(stringData: Data([1]), completion: nil)
        }
    }

    // A disconnected NativeEngine must surface the write failure instead of dropping it.
    func testNativeEngineReportsWriteErrorWhenNotConnected() {
        if #available(macOS 10.15, iOS 13.0, *) {
            let engine = NativeEngine()
            let expectation = self.expectation(description: "write error reported")
            engine.write(string: "hello", reportingError: { error in
                XCTAssertNotNil(error, "writing on a closed engine should report an error")
                expectation.fulfill()
            })
            wait(for: [expectation], timeout: 5)
        }
    }

    // A disconnected WSEngine must surface the "not connected" failure too.
    func testWSEngineReportsWriteErrorWhenNotConnected() {
        if #available(macOS 10.14, iOS 12.0, *) {
            let engine = WSEngine(transport: TCPTransport())
            let expectation = self.expectation(description: "write error reported")
            engine.write(string: "hello", reportingError: { error in
                XCTAssertNotNil(error, "writing on a closed engine should report an error")
                expectation.fulfill()
            })
            wait(for: [expectation], timeout: 5)
        }
    }

    // The WebSocket facade must forward the error through the reportingError callback.
    func testWebSocketFacadeReportsWriteError() {
        if #available(macOS 10.15, iOS 13.0, *) {
            let socket = WebSocket(request: URLRequest(url: URL(string: "ws://localhost:0")!), useCustomEngine: false)
            let expectation = self.expectation(description: "write error reported")
            socket.write(string: "hello", reportingError: { error in
                XCTAssertNotNil(error, "writing on a closed socket should report an error")
                expectation.fulfill()
            })
            wait(for: [expectation], timeout: 5)
        }
    }

    // A ping on a disconnected NativeEngine reports the error through the completion path
    // (the offline-verifiable half of the pong broadcast behavior; the pong itself needs a
    // live server and is covered by manual regression).
    func testNativeEnginePingOnDisconnectedReportsError() {
        if #available(macOS 10.15, iOS 13.0, *) {
            let engine = NativeEngine()
            let expectation = self.expectation(description: "ping error reported")
            engine.write(data: Data([1, 2, 3]), opcode: .ping, reportingError: { error in
                XCTAssertNotNil(error, "pinging a closed engine should report an error")
                expectation.fulfill()
            })
            wait(for: [expectation], timeout: 5)
        }
    }

    // MARK: - didCompleteWithError event mapping

    // The four shapes didCompleteWithError can take, and the event each must map to.

    // Records events so tests can inspect what the engine broadcast.
    private final class EventRecorder: EngineDelegate {
        private let lock = NSLock()
        private var events = [WebSocketEvent]()

        var recorded: [WebSocketEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }

        func didReceive(event: WebSocketEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }
    }

    private func makeEngineWithRecorder() -> (NativeEngine, EventRecorder) {
        let engine = NativeEngine()
        let recorder = EventRecorder()
        engine.register(delegate: recorder)
        return (engine, recorder)
    }

    // A dummy task for driving the delegate callbacks directly; the engine does not
    // check task identity, only its own shutdown bookkeeping.
    private func makeDummyTask() -> URLSessionWebSocketTask {
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: URL(string: "ws://localhost:1")!)
        return task
    }

    // A clean close handshake already delivered .disconnected; the trailing completion
    // (even with a nil error) must not stack a second terminal event on top of it.
    func testDidCompleteNilErrorAfterCloseHandshakeIsSilent() {
        let (engine, recorder) = makeEngineWithRecorder()
        engine.start(request: URLRequest(url: URL(string: "ws://localhost:1")!))
        let task = makeDummyTask()

        engine.urlSession(URLSession(), webSocketTask: task, didCloseWith: .normalClosure, reason: nil)
        engine.urlSession(URLSession(), task: task, didCompleteWithError: nil)

        let events = recorder.recorded
        XCTAssertEqual(events.count, 1)
        if case .disconnected = events[0] {} else {
            XCTFail("expected only .disconnected, got \(events)")
        }
    }

    // Client-requested cancel (stop()) without a completed close handshake maps to
    // .cancelled, not .error(NSURLErrorCancelled).
    func testDidCompleteCancelledAfterStopMapsToCancelled() {
        let (engine, recorder) = makeEngineWithRecorder()
        engine.start(request: URLRequest(url: URL(string: "ws://localhost:1")!))
        engine.stop(closeCode: 1000)

        let task = makeDummyTask()
        let cancelError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        engine.urlSession(URLSession(), task: task, didCompleteWithError: cancelError)

        let events = recorder.recorded
        XCTAssertEqual(events.count, 1)
        if case .cancelled = events[0] {} else {
            XCTFail("expected .cancelled, got \(events[0])")
        }
    }

    // The server went away without a close frame: nil error maps to .peerClosed, never
    // .error(nil) — callers must always get a terminal event they can act on.
    func testDidCompleteNilErrorWithoutCloseMapsToPeerClosed() {
        let (engine, recorder) = makeEngineWithRecorder()
        engine.start(request: URLRequest(url: URL(string: "ws://localhost:1")!))

        let task = makeDummyTask()
        engine.urlSession(URLSession(), task: task, didCompleteWithError: nil)

        let events = recorder.recorded
        XCTAssertEqual(events.count, 1)
        if case .peerClosed = events[0] {} else {
            XCTFail("expected .peerClosed, got \(events[0])")
        }
    }

    // A real transport failure still surfaces as .error.
    func testDidCompleteRealErrorMapsToError() {
        let (engine, recorder) = makeEngineWithRecorder()
        engine.start(request: URLRequest(url: URL(string: "ws://localhost:1")!))

        let task = makeDummyTask()
        let realError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        engine.urlSession(URLSession(), task: task, didCompleteWithError: realError)

        let events = recorder.recorded
        XCTAssertEqual(events.count, 1)
        if case .error(let error) = events[0] {
            XCTAssertEqual((error as NSError?)?.code, NSURLErrorTimedOut)
        } else {
            XCTFail("expected .error, got \(events[0])")
        }
    }
}
