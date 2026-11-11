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
    // Internal (not private) so tests can drive the delegate callbacks with the live task.
    var task: URLSessionWebSocketTask?
    private var session: URLSession?
    // Payloads of pings sent through write(data:opcode:completion:), oldest first. RFC 6455
    // guarantees pongs are returned in order, so the oldest payload matches the next pong.
    // Empty when the ping carried no payload; URLSessionWebSocketTask cannot echo a pong
    // payload back (its sendPing only sends empty pings), so the broadcast reuses the
    // request-side payload.
    private var pendingPingPayloads = [Data]()
    // Guards pendingPingPayloads: appended on the caller's thread (write(.ping)), popped
    // on URLSession's internal queue (pongReceiveHandler), cleared in start().
    private let pingPayloadsLock = NSLock()
    // didCloseWith already delivered the terminal .disconnected event; didCompleteWithError
    // fires afterwards for every shutdown (even with a nil error) and must not stack a
    // second terminal event on top of it.
    private var didReceiveClose = false
    // stop()/forceStop() were called by the client; the resulting completion is our own
    // doing (.cancelled), not a failure. Notably NSURLErrorCancelled WITHOUT this flag is
    // not a user stop — e.g. a rejected certificate-pinning challenge surfaces that way.
    private var stopRequested = false
    // The server-trust challenge was rejected by the certificate pinner; used to report
    // the ensuing cancellation as a security error instead of a bare cancellation.
    private var pinningRejected = false
    // Optional certificate pinning for the server-trust challenge. When nil, URLSession's
    // default handling applies (system trust evaluation).
    public var certificatePinner: CertificatePinning?
    weak var delegate: EngineDelegate?

    public func register(delegate: EngineDelegate) {
        self.delegate = delegate
    }

    public func start(request: URLRequest) {
        // URLSession retains its delegate (this engine) until invalidation. Tear down any
        // session left over from a previous run, or each reconnect would leak one session.
        closeSession()
        pingPayloadsLock.lock()
        pendingPingPayloads.removeAll()
        pingPayloadsLock.unlock()
        didReceiveClose = false
        stopRequested = false
        pinningRejected = false
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
        stopRequested = true
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
            pingPayloadsLock.lock()
            pendingPingPayloads.append(data)
            pingPayloadsLock.unlock()
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
        pingPayloadsLock.lock()
        defer { pingPayloadsLock.unlock() }
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
        guard webSocketTask === task else { return }
        let p = `protocol` ?? ""
        broadcast(event: .connected([HTTPWSHeader.protocolName: p]))
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        didReceiveClose = true
        var r = ""
        if let d = reason {
            r = String(data: d, encoding: .utf8) ?? ""
        }
        broadcast(event: .disconnected(r, UInt16(closeCode.rawValue)))
    }

    public func urlSession(_ session: URLSession, task completedTask: URLSessionTask, didCompleteWithError error: Error?) {
        // A stale completion from a task replaced by a newer start() must not poison the
        // current connection's event stream.
        guard completedTask === task else { return }
        // didCompleteWithError closes out every task, including clean ones. Map the possible
        // shapes onto the events callers actually need:
        // - clean close handshake already delivered .disconnected: nothing left to say
        // - client-requested stop()/forceStop(): .cancelled regardless of the arrival shape
        // - a cancellation we did not request (e.g. pinning rejected the challenge): .error
        //   (as a security error when we know pinning caused it)
        // - server went away without a close frame (nil error): .peerClosed, never .error(nil)
        // - everything else: a real transport error
        if didReceiveClose {
            return
        }
        if stopRequested {
            broadcast(event: .cancelled)
            return
        }
        if let error = error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
                && (error as NSError).domain == NSURLErrorDomain
            if cancelled {
                if pinningRejected {
                    broadcast(event: .error(WSError(type: .securityError, message: "certificate pinning failed", code: SecurityErrorCode.pinningFailed.rawValue)))
                } else {
                    // An unrequested cancellation (connection replaced, system teardown)
                    // is a failure from the caller's point of view.
                    broadcast(event: .error(error))
                }
            } else {
                broadcast(event: .error(error))
            }
        } else {
            broadcast(event: .peerClosed)
        }
    }

    // MARK: - URLSession authentication

    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let pinner = certificatePinner else {
            // No custom pinning requested (or not a server-trust challenge): let the system
            // trust evaluation decide.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        pinner.evaluateTrust(trust: trust, domain: challenge.protectionSpace.host, completion: { [weak self] state in
            switch state {
            case .success:
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .failed:
                self?.pinningRejected = true
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        })
    }
}
