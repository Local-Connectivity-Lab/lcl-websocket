//
//  File.swift
//
//
//  Created by Zhennan Zhou on 11/3/24.
//

import Foundation
import LCLWebSocket
import NIOPosix

if #available(macOS 13, *) {
    let config = LCLWebSocket.Configuration(
        autoPingConfiguration: .enabled(pingInterval: .seconds(4), pingTimeout: .seconds(10))
    )
    //    let elg = MultiThreadedEventLoopGroup.singleton
    let elg = LCLWebSocket.defaultEventloopGroup
    var client = WebSocketClient(on: elg)
    let promise = elg.next().makePromise(of: Void.self)

    client.onOpen { websocket in
        websocket.send(.init(string: "hello"), opcode: .text, promise: nil)
        websocket.ping()
    }
    client.onPing { _ in
        print("pinged")
    }

    try client.connect(to: "ws://127.0.0.1:8080", config: config).wait()
    //    let promise = websocket.channel.eventLoop.makePromise(of: Void.self)
    //    websocket.onPing { _ in
    //        print("ping")
    //    }
    //    websocket.send(.init(string: "hello"), opcode: .text, promise: nil)
    //    websocket.ping()

    try promise.futureResult.wait()
} else {
    // Fallback on earlier versions
    fatalError("Please run with macOS 13 or later")
}
