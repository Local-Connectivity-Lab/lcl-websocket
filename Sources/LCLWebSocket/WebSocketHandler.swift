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
import NIOFoundationCompat
import NIOWebSocket

final class WebSocketHandler: ChannelDuplexHandler {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    typealias OutboundIn = WebSocketFrame

    private let websocket: WebSocket
    private var firstBufferedFrame: WebSocketFrame?
    private var bufferedFrameData: ByteBuffer
    private var totalBufferedFrameCount: Int
    private let configuration: LCLWebSocket.Configuration
    private let extensions: [any WebSocketExtension]

    init(websocket: WebSocket, configuration: LCLWebSocket.Configuration, extensions: [any WebSocketExtensionOption]) {
        self.websocket = websocket
        self.firstBufferedFrame = nil
        self.bufferedFrameData = ByteBuffer()
        self.totalBufferedFrameCount = 0
        self.configuration = configuration
        self.extensions = extensions.compactMap { $0.makeExtension() }
    }

    #if DEBUG
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("WebSocketHandler channelInactive")
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        logger.debug("WebSocketHandler channelUnregistered")
    }
    #endif  // DEBUG

    // Validate if the frame is a valid WebSocket frame according to the opcode.
    // If the frame is the first frame in a fragmented sequence, this frame will be buffered.
    private func validateFrame(_ frame: WebSocketFrame) throws {
        switch frame.opcode {
        case .binary, .text:
            guard self.firstBufferedFrame == nil else {
                throw LCLWebSocketError.receivedNewFrameWithoutFinishingPreviousOne
            }
            if !frame.fin {
                self.firstBufferedFrame = frame
            }
        case .continuation:
            guard self.firstBufferedFrame != nil else {
                throw LCLWebSocketError.receivedContinuationFrameWithoutPreviousFragmentFrame
            }
        default:
            // ok
            ()
        }

        if self.extensions.isEmpty && (frame.rsv1 || frame.rsv2 || frame.rsv3)
            || (frame.opcode == .continuation && frame.rsv1)
        {
            throw LCLWebSocketError.invalidReservedBits
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = self.unwrapInboundIn(data)
        logger.debug("received frame: \(frame)")

        // check if the frame is valid
        do {
            try validateFrame(frame)
        } catch {
            logger.error("cannot verify frame: \(frame). Error: \(error)")
            self.websocket.close(
                code: .protocolError,
                reason: (error as? LCLWebSocketError).debugDescription,
                promise: nil
            )
            return
        }

        if let maskKey = frame.maskKey {
            frame.data.webSocketUnmask(maskKey)
        }

        // decode frame with extension, if any
        do {
            for var ext in self.extensions.reversed() {
                if (self.firstBufferedFrame ?? frame).reservedBits == ext.reservedBits {
                    frame = try ext.decode(frame: frame, allocator: context.channel.allocator)
                } else {
                    logger.debug("skip decoding with extension: \(ext)")
                }
            }
        } catch {
            logger.debug("Websocket extension decode error: \(error). Skip frame processing and close the channel.")
            self.websocket.close(code: .protocolError, promise: nil)
            return
        }

        do {
            switch frame.opcode {
            case .continuation:
                guard let firstFrame = self.firstBufferedFrame else {
                    // close channel due to policy violation
                    throw LCLWebSocketError.receivedContinuationFrameWithoutPreviousFragmentFrame
                }

                // buffer the frame
                try self.bufferFrame(frame)

                guard frame.fin else {
                    // continuation frame
                    break
                }

                // final frame is received
                // combine frame
                // clear buffer
                let combinedFrame = self.combineFrames(firstFrame: firstFrame, allocator: context.channel.allocator)
                self.websocket.handleFrame(combinedFrame)
                self.clearBufferedFrames()

            case .binary, .text:
                if frame.fin {
                    // unfragmented frame
                    self.websocket.handleFrame(frame)
                } else {
                    // fragmented frame
                    try self.bufferFrame(frame)
                }
            default:
                self.websocket.handleFrame(frame)
            }
        } catch LCLWebSocketError.invalidUTF8String, is ByteBuffer.ReadUTF8ValidationError {
            self.websocket.close(code: .dataInconsistentWithMessage, promise: nil)
            context.close(mode: .all, promise: nil)
            clearBufferedFrames()
        } catch {
            let reason = (error as? LCLWebSocketError)?.description
            self.websocket.close(code: .protocolError, reason: reason, promise: nil)
            context.close(mode: .all, promise: nil)
            clearBufferedFrames()
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var frame = self.unwrapOutboundIn(data)
        if frame.opcode == .binary || frame.opcode == .text || frame.opcode == .continuation {
            for var ext in self.extensions {
                do {
                    frame = try ext.encode(frame: frame, allocator: context.channel.allocator)
                } catch {
                    logger.error("websocket extension failed: \(error)")
                    promise?.fail(error)
                    return
                }
            }
        }
        context.writeAndFlush(self.wrapOutboundOut(frame), promise: promise)
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

    private func bufferFrame(_ frame: WebSocketFrame) throws {
        guard frame.fin || frame.length >= self.configuration.minNonFinalFragmentSize else {
            throw LCLWebSocketError.nonFinalFragmentSizeIsTooSmall
        }

        guard self.totalBufferedFrameCount < self.configuration.maxFrameSize else {
            throw LCLWebSocketError.tooManyFrameFragments
        }

        guard frame.fin || (self.totalBufferedFrameCount + 1) < self.configuration.maxAccumulatedFrameCount else {
            throw LCLWebSocketError.tooManyFrameFragments
        }

        self.totalBufferedFrameCount += 1
        var frame = frame
        self.bufferedFrameData.writeBuffer(&frame.data)

        guard self.bufferedFrameData.readableBytes <= self.configuration.maxAccumulatedFrameSize else {
            throw LCLWebSocketError.accumulatedFrameSizeIsTooLarge
        }
    }

    private func combineFrames(firstFrame: WebSocketFrame, allocator: ByteBufferAllocator) -> WebSocketFrame {
        WebSocketFrame(
            fin: firstFrame.fin,
            rsv1: firstFrame.rsv1,
            rsv2: firstFrame.rsv2,
            rsv3: firstFrame.rsv3,
            opcode: firstFrame.opcode,
            maskKey: firstFrame.maskKey,
            data: self.bufferedFrameData,
            extensionData: firstFrame.extensionData
        )
    }

    private func clearBufferedFrames() {
        self.firstBufferedFrame = nil
        self.bufferedFrameData.clear()
        self.totalBufferedFrameCount = 0
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
