//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  NativeEngine.swift
//  Starscream
//
//  Created by Dalton Cherry on 6/15/19
//  Copyright © 2019 Vluxe. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
/// Engine backed by URLSessionWebSocketTask.
///
/// URLSession-level limits compared to WSEngine, by design of URLSessionWebSocketTask:
/// - Pings sent here carry no payload on the wire; `.pong` events echo the request-side
///   payload back. Server-initiated pings are answered automatically by URLSession and are
///   never surfaced as `.ping` events (so respondToPingWithPong does not apply here).
/// - A pong that never arrives does not time out on its own; the failure only surfaces
///   through the write/ping completion. Callers implement their own pong timeout.
public class NativeEngine: NSObject, Engine, URLSessionDataDelegate, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    // Payloads of pings sent through write(data:opcode:completion:), oldest first. RFC 6455
    // guarantees pongs are returned in order, so the oldest payload matches the next pong.
    // Empty when the ping carried no payload; URLSessionWebSocketTask cannot echo a pong
    // payload back (its sendPing only sends empty pings), so the broadcast reuses the
    // request-side payload.
    private var pendingPingPayloads = [Data]()
    weak var delegate: EngineDelegate?

    public func register(delegate: EngineDelegate) {
        self.delegate = delegate
    }

    public func start(request: URLRequest) {
        // URLSession retains its delegate (this engine) until invalidation. Tear down any
        // session left over from a previous run, or each reconnect would leak one session.
        closeSession()
        pendingPingPayloads.removeAll()
        session = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
        task = session?.webSocketTask(with: request)
        doRead()
        task?.resume()
    }

    public func closeSession() {
        guard let session = session else { return }
        self.session = nil
        session.finishTasksAndInvalidate()
    }

    public func stop(closeCode: UInt16) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(closeCode)) ?? .normalClosure
        task?.cancel(with: closeCode, reason: nil)
    }

    public func forceStop() {
        stop(closeCode: UInt16(URLSessionWebSocketTask.CloseCode.abnormalClosure.rawValue))
    }

    public func write(string: String, completion: (() -> ())?) {
        task?.send(.string(string), completionHandler: { (error) in
            completion?()
        })
    }

    public func write(string: String, reportingError onError: ((Error?) -> ())?) {
        guard let task = task else {
            onError?(NativeEngine.notConnectedError)
            return
        }
        task.send(.string(string), completionHandler: { (error) in
            onError?(error)
        })
    }

    public func write(data: Data, opcode: FrameOpCode, completion: (() -> ())?) {
        write(data: data, opcode: opcode, reportingError: { _ in completion?() })
    }

    public func write(data: Data, opcode: FrameOpCode, reportingError onError: ((Error?) -> ())?) {
        guard task != nil else {
            onError?(NativeEngine.notConnectedError)
            return
        }
        switch opcode {
        case .binaryFrame:
            task?.send(.data(data), completionHandler: { (error) in
                onError?(error)
            })
        case .textFrame:
            guard let text = String(data: data, encoding: .utf8) else {
                onError?(WSError(type: .protocolError, message: "text frames must contain valid UTF-8", code: CloseCode.encoding.rawValue))
                return
            }
            write(string: text, reportingError: onError)
        case .ping:
            // URLSessionWebSocketTask.sendPing cannot carry a payload, so the pong the peer
            // returns is empty on the wire. The broadcast below reuses the request-side
            // payload so callers get the data they asked to ping with, matching WSEngine's
            // behavior of echoing the real pong payload. Callers keying on payload contents
            // should know this is request-side data, not what the peer actually sent back.
            pendingPingPayloads.append(data)
            task?.sendPing(pongReceiveHandler: { [weak self] (error) in
                guard let self = self else { return }
                // The callback runs on URLSession's internal queue; delegate delivery is the
                // caller's concern (WebSocket hops to callbackQueue anyway).
                let payload = self.nextPendingPingPayload()
                if error == nil {
                    // Only report a pong when one actually arrived; on error the connection
                    // is failing and the error below is the meaningful signal. Broadcasts
                    // before surfacing the error so observers see pong, then failure.
                    if let payload = payload {
                        self.broadcast(event: .pong(payload))
                    }
                }
                onError?(error)
            })
        default:
            break //unsupported
        }
    }

    private static let notConnectedError = WSError(type: .protocolError, message: "can't write, not connected", code: CloseCode.noStatusReceived.rawValue)

    // Pops the payload matching the pong that just arrived (FIFO). Returns nil when the
    // queue is empty, e.g. a sendPing issued outside this API — in that case no .pong is
    // broadcast because there is no payload to echo. Note the payload count can drift
    // from in-flight pings if a pong never arrives (dead connection); start() clears it.
    private func nextPendingPingPayload() -> Data? {
        guard !pendingPingPayloads.isEmpty else { return nil }
        return pendingPingPayloads.removeFirst()
    }

    private func doRead() {
        task?.receive { [weak self] (result) in
            switch result {
            case .success(let message):
                switch message {
                case .string(let string):
                    self?.broadcast(event: .text(string))
                case .data(let data):
                    self?.broadcast(event: .binary(data))
                @unknown default:
                    break
                }
                break
            case .failure(let error):
                self?.broadcast(event: .error(error))
                return
            }
            self?.doRead()
        }
    }

    private func broadcast(event: WebSocketEvent) {
        delegate?.didReceive(event: event)
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let p = `protocol` ?? ""
        broadcast(event: .connected([HTTPWSHeader.protocolName: p]))
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        var r = ""
        if let d = reason {
            r = String(data: d, encoding: .utf8) ?? ""
        }
        broadcast(event: .disconnected(r, UInt16(closeCode.rawValue)))
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        broadcast(event: .error(error))
    }
}
