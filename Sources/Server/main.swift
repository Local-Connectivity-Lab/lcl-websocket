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
    autoPingConfiguration: .disabled,
    leftoverBytesStrategy: .forwardBytes
)

let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
var server = LCLWebSocket.server(on: elg)
server.onPing { websocket, buffer in
    print("onPing: \(buffer)")
    websocket.pong(data: buffer)
}

server.onPong { ws, buffer in
    print("onPong: \(buffer)")
}

server.onBinary { websocket, buffer in
    websocket.send(buffer, opcode: .binary, promise: nil)
}

server.onText { websocket, text in
    print("received text: \(text)")
    websocket.send(.init(string: text), opcode: .text, promise: nil)
}
server.onClosing { code, reason in
    print("on closing: \(String(describing: code)), \(String(describing: reason))")
}

try server.listen(host: "127.0.0.1", port: 8080, configuration: config).wait()
