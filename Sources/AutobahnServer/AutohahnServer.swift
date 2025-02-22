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

@main
struct AutohahnServer {

    static let config = LCLWebSocket.Configuration(
        maxFrameSize: 1 << 25,
        autoPingConfiguration: .disabled,
        leftoverBytesStrategy: .forwardBytes
    )

    static let serverAddress = "127.0.0.1"
    static let serverPort = 9000

    static func main() throws {

        let args = CommandLine.arguments
        var port: Int = Self.serverPort
        precondition(args.count == 1 || args.count == 3, "Usage: \(args[0]) [--port <port>]")
        let portCmdIndex = args.firstIndex(where: { $0 == "--port" })
        if let portCmdIndex = portCmdIndex {
            let portIndex = portCmdIndex + 1
            port = Int(args[portIndex]) ?? port
        }

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        var server = LCLWebSocket.server(on: elg)

        server.onBinary { ws, buffer in
            ws.send(buffer, opcode: .binary)
        }

        server.onText { ws, text in
            ws.send(.init(string: text), opcode: .text)
        }

        try server.listen(host: Self.serverAddress, port: port, configuration: Self.config).wait()
    }
}
