//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Engine.swift
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

public protocol EngineDelegate: AnyObject {
    func didReceive(event: WebSocketEvent)
}

public protocol Engine: AnyObject {
    func register(delegate: EngineDelegate)
    func start(request: URLRequest)
    func stop(closeCode: UInt16)
    func forceStop()
    func write(data: Data, opcode: FrameOpCode, completion: (() -> ())?)
    func write(string: String, completion: (() -> ())?)

    /// Writes with write errors reported through the completion instead of being dropped.
    ///
    /// Engines that cannot surface a write error still invoke the callback with nil.
    /// Defaulted so custom engines keep compiling; conformers are encouraged to override.
    func write(data: Data, opcode: FrameOpCode, reportingError onError: ((Error?) -> ())?)
    func write(string: String, reportingError onError: ((Error?) -> ())?)
}

public extension Engine {
    func write(data: Data, opcode: FrameOpCode, reportingError onError: ((Error?) -> ())?) {
        write(data: data, opcode: opcode, completion: { onError?(nil) })
    }

    func write(string: String, reportingError onError: ((Error?) -> ())?) {
        write(string: string, completion: { onError?(nil) })
    }
}
