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
struct TestWebSocketClient {

    static let config = LCLWebSocket.Configuration(
        maxFrameSize: 1 << 16,
        autoPingConfiguration: .disabled,
        leftoverBytesStrategy: .forwardBytes
    )

    static let serverAddress = "127.0.0.1"
    static let serverPort = 9001
    static let agentName = "LCLWebSocketClient"

    public static func main() throws {

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var client = LCLWebSocket.client(on: elg)
        let totalTestCount = elg.any().makePromise(of: Int.self)

        client.onText { websocket, text in
            guard let total = Int(text) else {
                fatalError()
            }
            totalTestCount.succeed(total)
        }

        try client.connect(to: "ws://\(Self.serverAddress):\(Self.serverPort)/getCaseCount", configuration: Self.config)
            .wait()

        let total = try totalTestCount.futureResult.wait()
        print("Running total tests: \(total)")

        for i in 1...total {
            var client = LCLWebSocket.client(on: elg)
            client.onText { ws, text in
                ws.send(.init(string: text), opcode: .text)
            }
            client.onBinary { ws, binary in
                ws.send(binary, opcode: .binary)
            }
            try client.connect(
                to: "ws://\(Self.serverAddress):\(Self.serverPort)/runCase?case=\(i)&agent=\(Self.agentName)",
                configuration: Self.config
            ).wait()
        }

        let closeClient = LCLWebSocket.client()
        do {
            try closeClient.connect(
                to: "ws://\(Self.serverAddress):\(Self.serverPort)/updateReports?agent=\(Self.agentName)",
                configuration: Self.config
            ).wait()
        } catch {
            print("Error closing client: \(error)")
        }

    }
}
