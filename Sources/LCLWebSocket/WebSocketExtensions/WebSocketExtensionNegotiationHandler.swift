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
import NIOWebSocket

final class WebSocketExtensionNegotiationRequestHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    typealias OutboundIn = HTTPServerResponsePart

    private(set) var acceptedExtensions: [any WebSocketExtensionOption] = []
    private let supportedExtensions: [any WebSocketExtensionOption]

    init(supportedExtensions: [any WebSocketExtensionOption]) throws {
        if !validateExtensions(supportedExtensions) {
            throw WebSocketExtensionError.incompatibleExtensions
        }
        self.supportedExtensions = supportedExtensions
    }

    #if DEBUG
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("WebSocketExtensionNegotiationRequestHandler channelInactive")
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        logger.debug("WebSocketExtensionNegotiationRequestHandler channelUnregistered")
    }
    #endif  // DEBUG

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = self.unwrapInboundIn(data)
        switch request {
        case .head(let head):
            for ext in supportedExtensions {
                do {
                    if let result = try ext.negotiate(head.headers),
                        let neogitationResult = result as? any WebSocketExtensionOption
                    {
                        acceptedExtensions.append(neogitationResult)
                    }
                } catch {
                    logger.error("Cannot accept Websocket extension in \(head.headers). Error: \(error)")
                    context.fireErrorCaught(error)
                    return
                }
            }

            context.fireChannelRead(data)
        default:
            context.fireChannelRead(data)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let response = self.unwrapOutboundIn(data)
        switch response {

        case .head(let head):
            if head.status == .switchingProtocols {
                var newHeaders = HTTPHeaders()
                for header in head.headers {
                    newHeaders.add(name: header.name, value: header.value)
                }
                for acceptedExtension in acceptedExtensions {
                    let extensionHeader = acceptedExtension.httpHeader
                    newHeaders.add(name: extensionHeader.name, value: extensionHeader.val)
                }
                let responseHead = HTTPResponseHead(version: head.version, status: head.status, headers: newHeaders)
                context.write(self.wrapOutboundOut(.head(responseHead)), promise: promise)
            } else {
                fallthrough
            }
        default:
            context.write(data, promise: promise)
        }
    }
}

final class WebSocketExtensionNegotiationResponseHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias InboundOut = HTTPClientResponsePart

    private(set) var acceptedExtensions: [any WebSocketExtensionOption] = []
    private let supportedExtensions: [any WebSocketExtensionOption]
    private var upgradeResponseHeadersComplete: Bool

    init(supportedExtensions: [any WebSocketExtensionOption]) throws {
        if !validateExtensions(supportedExtensions) {
            throw WebSocketExtensionError.incompatibleExtensions
        }
        self.supportedExtensions = supportedExtensions
        self.upgradeResponseHeadersComplete = false
    }

    #if DEBUG
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("WebSocketExtensionNegotiationResponseHandler channelInactive")
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        logger.debug("WebSocketExtensionNegotiationResponseHandler channelUnregistered")
    }
    #endif  // DEBUG

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !self.upgradeResponseHeadersComplete {
            let response = self.unwrapInboundIn(data)
            switch response {
            case .head(let head):
                for ext in self.supportedExtensions {
                    do {
                        if let result = try ext.accept(head.headers),
                            let neogitationResult = result as? any WebSocketExtensionOption
                        {
                            acceptedExtensions.append(neogitationResult)
                        }
                    } catch {
                        logger.error("Cannot accept Websocket extension in \(head.headers). Error: \(error)")
                        context.fireErrorCaught(error)
                    }
                }

                context.fireChannelRead(data)
            case .end:
                self.upgradeResponseHeadersComplete = true
                context.fireChannelRead(data)
            default:
                context.fireChannelRead(data)
            }
        } else {
            context.fireChannelRead(data)
        }
    }
}

private func validateExtensions(_ extensions: [any WebSocketExtensionOption]) -> Bool {
    var tempSet = WebSocketFrame.ReservedBits()
    for extensionObject in extensions {
        if tempSet.isDisjoint(with: extensionObject.reservedBits) {
            tempSet.formUnion(extensionObject.reservedBits)
        } else {
            return false
        }
    }
    return true
}
