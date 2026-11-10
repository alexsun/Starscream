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
}
