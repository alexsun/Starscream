//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  CompressionTests.swift
//
//  Created by Joseph Ross on 7/16/14.
//  Copyright © 2017 Joseph Ross.
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

import XCTest
@testable import Starscream

class CompressionTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    func testBasic() {
        let compressor = Compressor(windowBits: 15)!
        let decompressor = Decompressor(windowBits: 15)!
        
        let rawData = "Hello, World! Hello, World! Hello, World! Hello, World! Hello, World!".data(using: .utf8)!
        
        let compressed = try! compressor.compress(rawData)
        let uncompressed = try! decompressor.decompress(compressed, finish: true)
        
        XCTAssert(rawData == uncompressed)
    }
    
    func testHugeData() {
        let compressor = Compressor(windowBits: 15)!
        let decompressor = Decompressor(windowBits: 15)!
        
        // 2 Gigs!
//        var rawData = Data(repeating: 0, count: 0x80000000)
        var rawData = Data(repeating: 0, count: 0x80000)
        let rawDataLen = rawData.count
        rawData.withUnsafeMutableBytes { (ptr: UnsafeMutablePointer<UInt8>) -> Void in
            arc4random_buf(ptr, rawDataLen)
        }
        
        let compressed = try! compressor.compress(rawData)
        let uncompressed = try! decompressor.decompress(compressed, finish: true)
        
        XCTAssert(rawData == uncompressed)
    }

    func testControlFramesAreNotCompressed() {
        let transport = FrameCapturingTransport()
        let engine = WSEngine(transport: transport, headerValidator: MockSecurity(), compressionHandler: WSCompression())
        engine.start(request: URLRequest(url: URL(string: "ws://localhost/ws")!))
        engine.didReceiveHTTP(event: .success(["Sec-WebSocket-Extensions": "permessage-deflate"]))

        let written = expectation(description: "frames written")
        written.expectedFulfillmentCount = 4
        transport.onWrite = { written.fulfill() }

        // The empty pong is what Starscream sends back for a server heartbeat ping.
        engine.write(data: Data(), opcode: .pong, completion: nil)
        engine.write(data: "ping".data(using: .utf8)!, opcode: .ping, completion: nil)
        engine.write(data: Data([0x03, 0xE8]), opcode: .connectionClose, completion: nil)
        engine.write(string: "Hello, World! Hello, World! Hello, World!", completion: nil)
        wait(for: [written], timeout: 5)

        let firstBytes = transport.frames.map { $0[0] }
        XCTAssertEqual(firstBytes[0], FinMask | FrameOpCode.pong.rawValue)
        XCTAssertEqual(firstBytes[1], FinMask | FrameOpCode.ping.rawValue)
        XCTAssertEqual(firstBytes[2], FinMask | FrameOpCode.connectionClose.rawValue)
        // Data frames are still compressed once permessage-deflate is negotiated.
        XCTAssertEqual(firstBytes[3], FinMask | RSV1Mask | FrameOpCode.textFrame.rawValue)
    }

}

private class FrameCapturingTransport: Transport {
    var frames = [Data]()
    var onWrite: (() -> Void)?

    var usingTLS: Bool {
        return false
    }

    func register(delegate: TransportEventClient) {}

    func connect(url: URL, timeout: Double, certificatePinning: CertificatePinning?) {}

    func disconnect() {}

    func write(data: Data, completion: @escaping ((Error?) -> ())) {
        frames.append(data)
        completion(nil)
        onWrite?()
    }
}
