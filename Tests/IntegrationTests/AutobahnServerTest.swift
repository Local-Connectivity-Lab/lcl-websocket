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
import NIOPosix
import XCTest

@testable import LCLWebSocket

private let config = LCLWebSocket.Configuration(
    maxFrameSize: 1 << 25,
    autoPingConfiguration: .disabled,
    leftoverBytesStrategy: .forwardBytes
)

private let serverAddress = "127.0.0.1"

final class AutobahnServerTest: XCTestCase {

    private func makeServer(port: Int, extensions: [any WebSocketExtensionOption] = []) throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        var server = LCLWebSocket.server(on: elg)

        server.onBinary { ws, buffer in
            ws.send(buffer, opcode: .binary)
        }

        server.onText { ws, text in
            ws.send(.init(string: text), opcode: .text)
        }

        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.main)
        signalSource.setEventHandler {
            print("SIGINT received. Cleaning up and exiting...")
            server.shutdown { error in
                if let error = error {
                    XCTFail(error.localizedDescription)
                }
            }
            exit(0)
        }

        // Start monitoring the signal
        signalSource.resume()
        try server.listen(host: serverAddress, port: port, configuration: config, supportedExtensions: extensions)
            .wait()
    }

    func testBasic() throws {
        try makeServer(port: 9002)
    }

    func testCase12() throws {
        try makeServer(port: 9003, extensions: [PerMessageDeflateExtensionOption(isServer: true)])
    }

    func testCase13_1() throws {
        try makeServer(port: 9004, extensions: [PerMessageDeflateExtensionOption(isServer: true)])
    }

    func testCase13_2() throws {
        try makeServer(
            port: 9005,
            extensions: [
                PerMessageDeflateExtensionOption(isServer: true, serverNoTakeover: true, clientNoTakeover: true)
            ]
        )
    }

    func testCase13_3() throws {
        try makeServer(
            port: 9006,
            extensions: [
                PerMessageDeflateExtensionOption(isServer: true, serverMaxWindowBits: 9, clientMaxWindowBits: 9)
            ]
        )
    }

    func testCase13_4() throws {
        try makeServer(
            port: 9007,
            extensions: [
                PerMessageDeflateExtensionOption(isServer: true, serverMaxWindowBits: 15, clientMaxWindowBits: 15)
            ]
        )
    }

    func testCase13_5() throws {
        try makeServer(
            port: 9008,
            extensions: [
                PerMessageDeflateExtensionOption(
                    isServer: true,
                    serverNoTakeover: true,
                    clientNoTakeover: true,
                    serverMaxWindowBits: 9,
                    clientMaxWindowBits: 9
                )
            ]
        )
    }

    func testCase13_6() throws {
        try makeServer(
            port: 9009,
            extensions: [
                PerMessageDeflateExtensionOption(
                    isServer: true,
                    serverNoTakeover: true,
                    clientNoTakeover: true,
                    serverMaxWindowBits: 15,
                    clientMaxWindowBits: 15
                )
            ]
        )
    }

    func testCase13_7() throws {
        try makeServer(
            port: 9010,
            extensions: [
                PerMessageDeflateExtensionOption(
                    isServer: true,
                    serverNoTakeover: true,
                    clientNoTakeover: true,
                    serverMaxWindowBits: 9,
                    clientMaxWindowBits: 9
                )
            ]
        )

    }
}
