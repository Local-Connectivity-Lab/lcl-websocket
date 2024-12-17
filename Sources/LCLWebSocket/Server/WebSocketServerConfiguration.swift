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

    public init(
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>,
        onUpgradeComplete: @escaping @Sendable (ChannelHandlerContext) -> Void
    ) {
        self.shouldUpgrade = shouldUpgrade
        self.onUpgradeComplete = onUpgradeComplete
    }
}

extension WebSocketServerConfiguration {
    public static let defaultConfiguration: WebSocketServerConfiguration = Self(
        shouldUpgrade: { channel, requestHead in
            // by default, all websocket connection will be refused
            channel.eventLoop.makeSucceededFuture(nil)
        },
        onUpgradeComplete: { context in
            print("server upgraded. onUpgradeComplete")
        }
    )
}
