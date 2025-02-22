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
    maxFrameSize: 1 << 24,
    autoPingConfiguration: .disabled,
    leftoverBytesStrategy: .forwardBytes
)

private let serverAddress = "127.0.0.1"
private let serverPort = 9001
private let agentName = "LCLWebSocketClient"

final class AutobahnClientTest: XCTestCase {

    struct TestResult: Decodable {
        let behavior: String
    }

    private static func getTestCount() throws -> Int {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var client = LCLWebSocket.client(on: elg)
        let totalTestCount = elg.any().makePromise(of: Int.self)

        client.onText { websocket, text in
            guard let total = Int(text) else {
                fatalError()
            }
            totalTestCount.succeed(total)
        }

        try client.connect(to: "ws://\(serverAddress):\(serverPort)/getCaseCount", configuration: config)
            .wait()

        let total = try totalTestCount.futureResult.wait()
        print("Running total tests: \(total)")
        client.shutdown { _ in }
        return total
    }

    func runTest(_ i: Int, extensions: [any WebSocketExtensionOption]) throws {
        let jsonDecoder = JSONDecoder()
        var client = LCLWebSocket.client()
        client.onText { ws, text in
            ws.send(.init(string: text), opcode: .text)
        }
        client.onBinary { ws, binary in
            ws.send(binary, opcode: .binary)
        }
        try client.connect(
            to: "ws://\(serverAddress):\(serverPort)/runCase?case=\(i)&agent=\(agentName)",
            configuration: config,
            supportedExtensions: extensions
        ).wait()

        // check for result
        let testResult = client.eventloopGroup.next().makePromise(of: TestResult.self)
        client.onText { ws, text in
            let data = Data(text.utf8)
            do {
                let decoded = try jsonDecoder.decode(TestResult.self, from: data)
                testResult.succeed(decoded)
            } catch {
                testResult.fail(error)
            }
        }
        try client.connect(
            to: "ws://\(serverAddress):\(serverPort)/getCaseStatus?case=\(i)&agent=\(agentName)",
            configuration: config,
            supportedExtensions: extensions
        ).wait()
        client.shutdown { _ in }
        let result = try testResult.futureResult.wait()
        XCTAssert(result.behavior == "OK" || result.behavior == "INFORMATIONAL" || result.behavior == "NON-STRICT")
    }

    override class func setUp() {
        do {
            let testCount = try getTestCount()
            XCTAssertEqual(testCount, 517)
        } catch {
            XCTFail()
        }
    }

    override class func tearDown() {
        let closeClient = LCLWebSocket.client()
        do {
            try closeClient.connect(
                to: "ws://\(serverAddress):\(serverPort)/updateReports?agent=\(agentName)",
                configuration: config
            ).wait()
        } catch {
            XCTFail("Error closing client: \(error)")
        }
    }

    func testBasicBehaviors() throws {
        for i in 1...301 {
            try runTest(i, extensions: [])
        }
    }

    func testCase12() throws {
        for i in 302...391 {
            try runTest(i, extensions: [PerMessageDeflateExtensionOption(isServer: false)])
        }
    }

    func testCase13_1() throws {
        for i in 392...409 {
            try runTest(i, extensions: [PerMessageDeflateExtensionOption(isServer: false)])
        }
    }

    func testCase13_2() throws {
        for i in 410...427 {
            try runTest(
                i,
                extensions: [
                    PerMessageDeflateExtensionOption(isServer: false, serverNoTakeover: true, clientNoTakeover: true)
                ]
            )
        }
    }

    func testCase13_3() throws {
        for i in 428...445 {
            try runTest(
                i,
                extensions: [
                    PerMessageDeflateExtensionOption(isServer: false, serverMaxWindowBits: 9, clientMaxWindowBits: 9)
                ]
            )
        }
    }

    func testCase13_4() throws {
        for i in 446...463 {
            try runTest(
                i,
                extensions: [
                    PerMessageDeflateExtensionOption(isServer: false, serverMaxWindowBits: 15, clientMaxWindowBits: 15)
                ]
            )
        }
    }

    func testCase13_5() throws {
        for i in 464...481 {
            try runTest(
                i,
                extensions: [
                    PerMessageDeflateExtensionOption(
                        isServer: false,
                        serverNoTakeover: true,
                        clientNoTakeover: true,
                        serverMaxWindowBits: 9,
                        clientMaxWindowBits: 9
                    )
                ]
            )
        }
    }

    func testCase13_6() throws {
        for i in 482...499 {
            try runTest(
                i,
                extensions: [
                    PerMessageDeflateExtensionOption(
                        isServer: false,
                        serverNoTakeover: true,
                        clientNoTakeover: true,
                        serverMaxWindowBits: 15,
                        clientMaxWindowBits: 15
                    )
                ]
            )
        }
    }

    func testCase13_7() throws {
        for i in 500...517 {
            try runTest(
                i,
                extensions: [
                    PerMessageDeflateExtensionOption(
                        isServer: false,
                        serverNoTakeover: true,
                        clientNoTakeover: true,
                        serverMaxWindowBits: 9,
                        clientMaxWindowBits: 9
                    )
                ]
            )
            try runTest(
                i,
                extensions: [
                    PerMessageDeflateExtensionOption(isServer: false, serverNoTakeover: true, clientNoTakeover: true)
                ]
            )
            try runTest(i, extensions: [PerMessageDeflateExtensionOption(isServer: false)])
        }
    }
}
