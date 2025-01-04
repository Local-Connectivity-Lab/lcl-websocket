//
//  File.swift
//  LCLWebSocket
//
//  Created by Zhennan Zhou on 12/15/24.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

public struct WebSocketServerConfiguration: Sendable {
    public var shouldUpgrade: @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>
    public var onUpgradeComplete: @Sendable (ChannelHandlerContext) -> Void
    public var rejectResponse: String?

    public init(
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>,
        onUpgradeComplete: @escaping @Sendable (ChannelHandlerContext) -> Void,
        rejectResponse: String? = nil
    ) {
        self.shouldUpgrade = shouldUpgrade
        self.onUpgradeComplete = onUpgradeComplete
        self.rejectResponse = rejectResponse
    }
}

extension WebSocketServerConfiguration {
    public static let defaultConfiguration: WebSocketServerConfiguration = Self(
        shouldUpgrade: { channel, requestHead in
            // by default, all websocket connection will be refused
//            print("will reject the upgrade request. http header: \(requestHead)")
            let httpHeaders = HTTPHeaders([("User-Agent", "LCLWebSocketServer")])
            
            return channel.eventLoop.makeSucceededFuture(httpHeaders)
        },
        onUpgradeComplete: { _ in
            print("server upgraded. onUpgradeComplete")
        }
    )
}
