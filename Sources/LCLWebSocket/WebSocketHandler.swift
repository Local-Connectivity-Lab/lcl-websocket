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

import NIOCore
import NIOWebSocket

final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private let websocket: WebSocket
    init(websocket: WebSocket) {
        self.websocket = websocket
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("WebSocketHandler channelInactive")
    }
    
    func channelUnregistered(context: ChannelHandlerContext) {
        logger.debug("WebSocketHandler channelUnregistered")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.websocket.handleFrame(frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        logger.debug("WebSocketHandler caught error: \(error)")
        if let err = error as? NIOWebSocketError {
            self.websocket.close(
                code: WebSocketErrorCode(err),
                promise: nil
            )
        }
        context.close(mode: .all, promise: nil)
    }
}

extension WebSocketErrorCode {
    init(_ error: NIOWebSocketError) {
        switch error {
        case .invalidFrameLength:
            self = .messageTooLarge
        case .fragmentedControlFrame, .multiByteControlFrameLength:
            self = .protocolError
        }
    }
}
