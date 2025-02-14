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

final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private let websocket: WebSocket
    private var firstFrame: WebSocketFrame?
    private var bufferedFrameData: ByteBuffer
    private var totalBufferedFrameCount: Int
    private let configuration: LCLWebSocket.Configuration
    init(websocket: WebSocket, configuration: LCLWebSocket.Configuration) {
        self.websocket = websocket
        self.firstFrame = nil
        self.bufferedFrameData = ByteBuffer()
        self.totalBufferedFrameCount = 0
        self.configuration = configuration
    }

    #if DEBUG
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("WebSocketHandler channelInactive")
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        logger.debug("WebSocketHandler channelUnregistered")
    }
    #endif  // DEBUG

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = self.unwrapInboundIn(data)
        if let maskKey = frame.maskKey {
            frame.data.webSocketUnmask(maskKey)
        }
        
        do {
            switch frame.opcode {
            case .continuation:
                guard let firstFrame = self.firstFrame else {
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
                try validateUFT8Encoding(of: combinedFrame.data)
                self.websocket.handleFrame(combinedFrame)
                self.clearBufferedFrames()

            case .binary, .text:
                if frame.fin {
                    // unfragmented frame
                    guard self.firstFrame == nil else {
                        // close channel due to policy violatioin
                        throw LCLWebSocketError.receivedNewFrameWithoutFinishingPreviousOne
                    }
                    try validateUFT8Encoding(of: frame.data)

                    self.websocket.handleFrame(frame)
                } else {
                    // fragmented frame
                    try self.bufferFrame(frame)
                    return
                }
            default:
                self.websocket.handleFrame(frame)
            }
        } catch LCLWebSocketError.invalidUTF8String, is ByteBuffer.ReadUTF8ValidationError {
            self.websocket.close(code: .dataInconsistentWithMessage, promise: nil)
            context.close(mode: .all, promise: nil)
        } catch {
            let reason = (error as? LCLWebSocketError)?.description
            self.websocket.close(code: .protocolError, reason: reason, promise: nil)
            context.close(mode: .all, promise: nil)
        }
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
        guard self.firstFrame == nil || frame.opcode == .continuation else {
            throw LCLWebSocketError.receivedNewFrameWithoutFinishingPreviousOne
        }
        
        guard frame.fin || frame.length >= self.configuration.minNonFinalFragmentSize else {
            throw LCLWebSocketError.nonFinalFragmentSizeIsTooSmall
        }
        
        guard self.totalBufferedFrameCount < self.configuration.maxFrameSize else {
            throw LCLWebSocketError.tooManyFrameFragments
        }
        
        guard frame.fin || (self.totalBufferedFrameCount + 1) < self.configuration.maxAccumulatedFrameCount else {
            throw LCLWebSocketError.tooManyFrameFragments
        }
        
        if self.firstFrame == nil {
            self.firstFrame = frame
        }
        self.totalBufferedFrameCount += 1
        var frame = frame
        self.bufferedFrameData.writeBuffer(&frame.data)
        
        guard self.bufferedFrameData.readableBytes <= self.configuration.maxAccumulatedFrameSize else {
            throw LCLWebSocketError.accumulatedFrameSizeIsTooLarge
        }
    }
    
    private func validateUFT8Encoding(of data: ByteBuffer) throws {
        if data.readableBytes == 0 {
            return
        }
        
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) {
            _ = try self.bufferedFrameData.getUTF8ValidatedString(at: data.readableBytes, length: data.readableBytes)
        } else {
            guard let bytes = self.bufferedFrameData.getData(at: data.readerIndex, length: data.readableBytes), String(data: bytes, encoding: .utf8) != nil else {
                throw LCLWebSocketError.invalidUTF8String
            }
        }
    }
    
    private func combineFrames(firstFrame: WebSocketFrame, allocator: ByteBufferAllocator) -> WebSocketFrame {
        return WebSocketFrame(fin: firstFrame.fin, rsv1: firstFrame.rsv1, rsv2: firstFrame.rsv2, rsv3: firstFrame.rsv3, opcode: firstFrame.opcode, maskKey: firstFrame.maskKey, data: self.bufferedFrameData, extensionData: firstFrame.extensionData)
    }
    
    private func clearBufferedFrames() {
        self.firstFrame = nil
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
