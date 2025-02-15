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
import NIOCore
import NIOHTTP1
import NIOPosix

/// The configuration to configure various behaviors for the WebSocket server.
public struct WebSocketServerUpgradeConfiguration: Sendable {
    public var shouldUpgrade: @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>
    public var onUpgradeComplete: @Sendable (ChannelHandlerContext) -> Void
    public var rejectResponse: String?

    /// Initialize a `WebSocketServerConfiguration` instance to configure a WebSocket server instance
    ///
    /// - Parameters:
    ///     - shouldUpgrade: a callback function that defines whether the WebSocket upgrade should be granted, given the HTTP request header from the client.
    ///     - onUpgradeComplete: a callback function that will be invoked when the upgrade is complete.
    ///     - rejectResponse: a message that will be sent to the client if the WebSocket upgrade is rejected.
    public init(
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>,
        onUpgradeComplete: @escaping @Sendable (ChannelHandlerContext) -> Void,
        rejectResponse: String? = nil
    ) {
        self.onUpgradeComplete = onUpgradeComplete
        self.rejectResponse = rejectResponse
        self.shouldUpgrade = shouldUpgrade
    }
}

extension WebSocketServerUpgradeConfiguration {

    /// Default cofiguration for a WebSocketServer instance.
    ///
    /// - Note: By default, all websocket connection will be accepted.
    public static let defaultConfiguration: WebSocketServerUpgradeConfiguration = Self(
        shouldUpgrade: { channel, requestHead in
            let httpHeaders = HTTPHeaders([("User-Agent", "LCLWebSocketServer")])
            logger.debug("received  request header: \(requestHead)")
            logger.debug("\(requestHead.headers[canonicalForm: "Sec-WebSocket-Extensions"])")
            return channel.eventLoop.makeSucceededFuture(httpHeaders)
        },
        onUpgradeComplete: { _ in
            logger.info("server upgraded. onUpgradeComplete")
        }
    )
}
