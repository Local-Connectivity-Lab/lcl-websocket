//
// This source file is part of the LCL open source project
//
// Copyright (c) 2021-2024 Local Connectivity Lab and the project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of project authors
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import LCLWebSocket
import NIOCore
import NIOPosix

let config = LCLWebSocket.Configuration(
    maxFrameSize: 1 << 16,
    autoPingConfiguration: .enabled(pingInterval: .seconds(4), pingTimeout: .seconds(10)),
    leftoverBytesStrategy: .forwardBytes
)

// Initialize the client
var client = LCLWebSocket.client()
client.onOpen { websocket in
    websocket.send(.init(string: "hello"), opcode: .text, promise: nil)
}

client.onBinary { websocket, binary in
    print("received binary: \(binary)")
}

client.onText { websocket, text in
    print("received text: \(text)")
}

try client.connect(to: "ws://127.0.0.1:8080", configuration: config).wait()
