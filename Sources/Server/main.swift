//
//  Untitled.swift
//  LCLWebSocket
//
//  Created by Zhennan Zhou on 12/12/24.
//

import Foundation
import LCLWebSocket
import NIOCore
import NIOPosix

if #available(macOS 13, *) {
    let config = LCLWebSocket.Configuration(
        autoPingConfiguration: .enabled(pingInterval: .seconds(4), pingTimeout: .seconds(5))
    )
    let elg = MultiThreadedEventLoopGroup.singleton
    let promise = elg.next().makePromise(of: Void.self)
    var server = WebSocketServer(on: elg)
    server.onPing { ws, buffer in
        print("onPing: \(buffer)")
    }
    server.onPong { ws, buffer in
        print("onPong: \(buffer)")
    }
    server.onBinary { ws, buffer in
        print("onBinary: \(buffer).\n \(buffer.readableBytes) bytes")
    }

    let addr = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 8080)
    server.listen(to: addr, configuration: config)
    try promise.futureResult.wait()
} else {
    // Fallback on earlier versions
    fatalError("Please run with macOS 13 or later")
}
