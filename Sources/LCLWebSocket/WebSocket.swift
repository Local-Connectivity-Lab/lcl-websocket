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
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public final class WebSocket: Sendable {

    typealias TimerTracker = [String: NIOScheduledCallback]
    private static let pingIDLength = 36

    public let channel: Channel
    let type: WebSocketType
    private let configuration: LCLWebSocket.Configuration
    private let state: NIOLockedValueBox<WebSocketState>
    private let timerTracker: NIOLockedValueBox<TimerTracker>
    private let connectionInfo: ConnectionInfo
    //    private let extensions: [any WebSocketExtension]

    // MARK: callbacks
    private let _onPing: NIOLoopBoundBox<(@Sendable (WebSocket, ByteBuffer) -> Void)?>
    private let _onPong: NIOLoopBoundBox<(@Sendable (WebSocket, ByteBuffer) -> Void)?>
    private let _onText: NIOLoopBoundBox<(@Sendable (WebSocket, String) -> Void)?>
    private let _onBinary: NIOLoopBoundBox<(@Sendable (WebSocket, ByteBuffer) -> Void)?>
    private let _onClosing: NIOLoopBoundBox<(@Sendable (WebSocketErrorCode?, String?) -> Void)?>
    private let _onClosed: NIOLoopBoundBox<(@Sendable () -> Void)?>
    private let _onError: NIOLoopBoundBox<(@Sendable (Error) -> Void)?>

    public init(
        channel: Channel,
        type: WebSocketType,
        configuration: LCLWebSocket.Configuration,
        connectionInfo: ConnectionInfo
    ) {
        self.channel = channel
        self.type = type
        self.configuration = configuration
        self.state = .init(.open)
        self.timerTracker = .init([:])
        self._onPing = .makeEmptyBox(eventLoop: channel.eventLoop)
        self._onPong = .makeEmptyBox(eventLoop: channel.eventLoop)
        self._onText = .makeEmptyBox(eventLoop: channel.eventLoop)
        self._onBinary = .makeEmptyBox(eventLoop: channel.eventLoop)
        self._onError = .makeEmptyBox(eventLoop: channel.eventLoop)
        self._onClosing = .makeEmptyBox(eventLoop: channel.eventLoop)
        self._onClosed = .makeEmptyBox(eventLoop: channel.eventLoop)
        self.connectionInfo = connectionInfo
        //        self.extensions = self.connectionInfo.extensions?.compactMap { $0.makeExtension() }.reversed() ?? []
        if self.configuration.autoPingConfiguration.keepAlive {
            self.scheduleNextPing()
        }
    }

    deinit {
        logger.debug("websocket deinit. going away ...")
    }

    /// The WebSocket URL that the client connects to
    /// If this WebSocket is a server, then the url is nil.
    public var url: String? {
        self.connectionInfo.url?.description
    }

    /// The amount of buffer, in bytes, that is currently buffered, waiting to be sent to the remote peer.
    public var bufferedAmount: EventLoopFuture<Int> {
        self.channel.getOption(.bufferedWritableBytes)
    }

    /// The WebSocket protocol used by this connection. It is either "ws" or "wss"
    public var `protocol`: String? {
        self.connectionInfo.protocol
    }

    func onPing(_ callback: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onPing.value = callback
    }

    func onPong(_ callback: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onPong.value = callback
    }

    func onText(_ callback: (@Sendable (WebSocket, String) -> Void)?) {
        self._onText.value = callback
    }

    func onBinary(_ callback: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onBinary.value = callback
    }

    func onClosing(_ callback: (@Sendable (WebSocketErrorCode?, String?) -> Void)?) {
        self._onClosing.value = callback
    }

    func onClosed(_ callback: (@Sendable () -> Void)?) {
        self._onClosed.value = callback
    }

    func onError(_ callback: (@Sendable (Error) -> Void)?) {
        self._onError.value = callback
    }

    /// Send the provided buffer, opcode, fin to the remote WebSocket peer.
    ///
    /// - Parameters:
    ///   - buffer: the buffer to be sent to the remote peer
    ///   - opcode: the opcode used to describe the purpose of this WebSocket frame. See `WebSocketOpcode`
    ///   - fin: the fin code indicate that the message is fragmented or not.
    ///   - promise: a `EventLoopPromise` that will be fulfilled once the send is complete.
    public func send(
        _ buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        if !self.channel.isActive {
            logger.debug("channel is not active anymore. Skip sending the buffer.")
            promise?.fail(LCLWebSocketError.channelNotActive)
            return
        }

        switch (self.state.withLockedValue({ $0 }), opcode) {
        case (.open, _), (.closing, .connectionClose):
            var frame = WebSocketFrame(
                fin: fin,
                opcode: opcode,
                maskKey: self.makeMaskingKey(),
                data: buffer
            )
            //
            //            if opcode == .binary || opcode == .text {
            //                for var ext in self.extensions {
            //                    do {
            //                        frame = try ext.encode(frame: frame, allocator: self.channel.allocator)
            //                    } catch {
            //                        logger.error("websocket extension failed: \(error)")
            //                        promise?.fail(error)
            //                        return
            //                    }
            //                }
            //            }

            logger.debug("sent: \(frame)")
            self.channel.writeAndFlush(frame, promise: promise)
        case (.closed, _), (.closing, _):
            logger.warning("Connection is already closed. Should not send any more frames")
        default:
            logger.error("websocket is not in connected state")
            promise?.fail(LCLWebSocketError.websocketNotConnected)
            self._onError.value?(LCLWebSocketError.websocketNotConnected)
        }
    }

    /// Send the provided buffer, opcode, fin to the remote WebSocket peer.
    ///
    /// - Parameters:
    ///   - buffer: the buffer to be sent to the remote peer
    ///   - opcode: the opcode used to describe the purpose of this WebSocket frame. See `WebSocketOpcode`
    ///   - fin: the fin code indicate that the message is fragmented or not.
    ///
    /// - Returns: a `EventLoopPromise` that will be fulfilled once the send is complete.
    public func send(
        _ buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true
    ) -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.send(buffer, opcode: opcode, fin: fin, promise: promise)
        return promise.futureResult
    }

    /// Send the close frame to the WebSocket peer to initiate the closing handshake.
    ///
    /// - Parameters:
    ///   - code: the `WebSocketErrorCode` describe the reason for the closure.
    ///   - reason: the textual description of the reason why the WebSocket connection is closed.
    ///   - promise: A `EventLoopPromise` that will be fulfilled once the close operation is complete.
    public func close(
        code: WebSocketErrorCode = .normalClosure,
        reason: String? = nil,
        promise: EventLoopPromise<Void>? = nil
    ) {
        if !self.channel.isActive {
            promise?.fail(LCLWebSocketError.channelNotActive)
            self._onError.value?(LCLWebSocketError.channelNotActive)
            logger.error("channel is not active! No more close frame will be sent.")
            return
        }

        switch self.state.withLockedValue({ $0 }) {
        case .closed:
            logger.warning("WebSocket connection is already closed. No more close frame will be sent.")
            promise?.succeed(())
        case .closing:
            promise?.succeed(())
            logger.info("Waiting for peer to finish the closing handshake.")
        case .open:
            self.state.withLockedValue { $0 = .closing }
            var codeToSend = UInt16(webSocketErrorCode: code)
            if codeToSend == 1005 || codeToSend == 1006 {
                codeToSend = UInt16(webSocketErrorCode: .normalClosure)
            }

            var buffer = channel.allocator.buffer(capacity: reason == nil ? 2 : 125)
            buffer.writeInteger(codeToSend)

            if let reason = reason {
                if reason.utf8.count > 123 {
                    promise?.fail(LCLWebSocketError.closeReasonTooLong)
                } else {
                    buffer.writeString(reason)
                }
            }
            self.send(buffer, opcode: .connectionClose, fin: true, promise: promise)
        default:
            promise?.fail(LCLWebSocketError.channelNotActive)
            self._onError.value?(LCLWebSocketError.channelNotActive)
        }
    }

    /// Send the close frame to the WebSocket peer to initiate the closing handshake.
    ///
    /// - Parameters:
    ///   - code: the `WebSocketErrorCode` describe the reason for the closure.
    ///   - reason: the textual description of the reason why the WebSocket connection is closed.
    ///
    /// - Returns : A `EventLoopPromise` that will be fulfilled once the close operation is complete.
    public func close(
        code: WebSocketErrorCode = .normalClosure,
        reason: String? = nil
    ) -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.close(code: code, reason: reason, promise: promise)
        return promise.futureResult
    }

    /// Send the ping frame to the remote peer.
    ///
    /// Calling this function if the WebSocket connection is not active will result in a failure in the given promise.
    ///
    /// - Parameters:
    ///   - data: the data that will be included in the ping frame to the peer.
    ///   - promise: A `EventLoopPromise` that will be fulfilled once the ping operation is complete
    public func ping(data: ByteBuffer = .init(), promise: EventLoopPromise<Void>? = nil) {
        if !self.channel.isActive {
            promise?.fail(LCLWebSocketError.channelNotActive)
            self._onError.value?(LCLWebSocketError.channelNotActive)
            return
        }

        switch self.state.withLockedValue({ $0 }) {
        case .open:
            self.send(data, opcode: .ping, fin: true, promise: promise)
        default:
            promise?.fail(LCLWebSocketError.websocketNotConnected)
            self._onError.value?(LCLWebSocketError.websocketNotConnected)
        }
    }

    /// Send the pong frame to the remote peer.
    ///
    /// Calling this function if the WebSocket connection is not active will result in a failure in the given promise.
    ///
    /// - Parameters:
    ///   - data: the data that will be included in the pong frame to the peer.
    ///   - promise: A `EventLoopPromise` that will be fulfilled once the ping operation is complete
    public func pong(data: ByteBuffer = .init(), promise: EventLoopPromise<Void>? = nil) {
        if !self.channel.isActive {
            promise?.fail(LCLWebSocketError.channelNotActive)
            self._onError.value?(LCLWebSocketError.channelNotActive)
            return
        }

        switch self.state.withLockedValue({ $0 }) {
        case .open:
            self.send(data, opcode: .pong, promise: promise)
        default:
            promise?.fail(LCLWebSocketError.websocketNotConnected)
            self._onError.value?(LCLWebSocketError.websocketNotConnected)
        }
    }

    func handleFrame(_ frame: WebSocketFrame) {

        if !self.channel.isActive || self.state.withLockedValue({ $0 }) == .closed {
            logger.debug("channel is not active or is already closed. Skip frame processing for \(frame).")
            return
        }

        logger.debug("frame received: \(frame)")
        // TODO: the following applies to websocket without extension negotiated.
        // Note: Extension support will come later
        //        if self.extensions.isEmpty && (frame.rsv1 || frame.rsv2 || frame.rsv3) {
        //            self.closeChannel()
        //            return
        //        }

        //        var frame = frame
        //        if let maskKey = frame.maskKey {
        //            frame.data.webSocketUnmask(maskKey)
        //        }

        // apply extension
        //        for var ext in self.extensions {
        //            do {
        //                frame = try ext.decode(frame: frame, allocator: self.channel.allocator)
        //            } catch {
        //                logger.debug("Websocket extension decode error: \(error). Skip frame processing and close the channel.")
        //                self.closeChannel()
        //                return
        //            }
        //        }

        var data = frame.data
        let originalDataReaderIdx = data.readerIndex

        switch frame.opcode {
        case .binary:
            self._onBinary.value?(self, data)
        case .text:
            if data.readableBytes > 0 {
                guard let text = data.readString(length: data.readableBytes, encoding: .utf8) else {
                    // TODO: should the connection be closed or reply with error code?
                    self.close(code: .dataInconsistentWithMessage, promise: nil)
                    return
                }
                self._onText.value?(self, text)
            } else {
                self._onText.value?(self, "")
            }
        case .connectionClose:
            // if a previous close frame is received
            // if we have sent a close frame
            // we should not send more frame
            // mark the state as closed
            // if we have not sent a close frame
            // we send the close frame, with the same application data

            switch self.state.withLockedValue({ $0 }) {
            case .closing:
                logger.debug("Closing handshake complete")
                self.becomeClosed()
                if self.type == .server {
                    self.closeChannel()
                }
            case .closed:
                // should be filtered by the first if condition
                ()
            case .open:
                logger.debug("will close the connection")

                switch data.readableBytes {
                case 0:
                    self._onClosing.value?(nil, nil)
                case 2...125:
                    guard let closeCode = data.readWebSocketErrorCode() else {
                        self.becomeClosed()
                        self.closeChannel()
                        return
                    }
                    switch closeCode {
                    case .unknown(let code):
                        switch code {
                        case 3000..<5000:
                            break
                        default:
                            self.becomeClosed()
                            self.closeChannel()
                            return
                        }
                    default:
                        break
                    }

                    let bytesLeftForReason = data.readableBytes
                    let reason = data.readString(length: data.readableBytes, encoding: .utf8)

                    if bytesLeftForReason > 0 && reason == nil {
                        self.becomeClosed()
                        self.closeChannel()
                        return
                    }
                    self._onClosing.value?(closeCode, reason)
                default:
                    self.becomeClosed()
                    self.closeChannel()
                    return
                }

                self.state.withLockedValue { $0 = .closing }
                data.moveReaderIndex(to: originalDataReaderIdx)
                self.send(data, opcode: .connectionClose, promise: nil)
                self.becomeClosed()
                if self.type == .server {
                    self.closeChannel()
                }
            default:
                preconditionFailure("WebSocket connection is not established.")
            }
        case .continuation:
            preconditionFailure("continuation frame is filtered by swiftnio")
        case .ping:
            if frame.fin {
                self._onPing.value?(self, data)
                self.pong(data: data)
            } else {
                // error: control frame should not be fragmented
                self._onError.value?(LCLWebSocketError.controlFrameShouldNotBeFragmented)
                self.closeChannel()
            }
        case .pong:
            if frame.fin {
                // if there is no previous ping, unsolicited, a reponse is not expected
                self._onPong.value?(self, data)
                if frame.length == WebSocket.pingIDLength {
                    let id = data.readString(length: data.readableBytes)
                    self.timerTracker.withLockedValue { tracker in
                        if let id = id, let callback = tracker.removeValue(forKey: id) {
                            callback.cancel()
                        }
                    }
                }
            } else {
                self._onError.value?(LCLWebSocketError.controlFrameShouldNotBeFragmented)
                self.closeChannel()
            }
        default:
            self._onError.value?(LCLWebSocketError.unknownOpCode(frame.opcode))
            self.closeChannel()
        }
    }

    private func makeMaskingKey() -> WebSocketMaskingKey? {
        switch self.type {
        case .client:
            return WebSocketMaskingKey.random()
        case .server:
            return nil
        }
    }

    private func closeChannel() {
        if self.channel.isActive && self.channel.isWritable {
            logger.debug("Closing underying tcp connection.")
            self.channel.close(mode: .all, promise: nil)
        }
    }
}

extension WebSocket {
    private func becomeClosed() {
        self.state.withLockedValue { $0 = .closed }
        self._onClosed.value?()
        logger.debug("connection closed")
    }
}

extension WebSocket {
    // Schedule next ping frame to the peer.
    private func scheduleNextPing() {
        self.channel.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(0),
            delay: self.configuration.autoPingConfiguration.pingInterval
        ) { repeatTask in
            if !self.channel.isActive {
                logger.debug("channel is not active")
                repeatTask.cancel()
                return
            }

            switch self.state.withLockedValue({ $0 }) {
            case .connecting:
                // do nothing until the websocket connection is establish.
                ()
            case .open:
                // TODO: schedule task to check if timeout occurs
                let id = UUID().uuidString
                logger.debug("id: \(id)")
                let callback = try self.channel.eventLoop.scheduleCallback(
                    in: self.configuration.autoPingConfiguration.pingInterval,
                    handler: WebSocketKeepAliveCallbackHandler(
                        websocket: self,
                        id: id,
                        timerTracker: self.timerTracker
                    )
                )
                self.timerTracker.withLockedValue { $0[id] = callback }
                self.ping(data: .init(string: id))
            case .closing, .closed:
                repeatTask.cancel()
            }
        }
    }

    internal struct WebSocketKeepAliveCallbackHandler: NIOScheduledCallbackHandler, Sendable {
        private let id: String
        private let timerTracker: NIOLockedValueBox<TimerTracker>
        private let websocket: WebSocket
        init(websocket: WebSocket, id: String, timerTracker: NIOLockedValueBox<TimerTracker>) {
            self.websocket = websocket
            self.id = id
            self.timerTracker = timerTracker
        }

        func handleScheduledCallback(eventLoop: some EventLoop) {
            if self.websocket.channel.isActive {
                logger.debug("channel is still active. time out! \(self.id)")
                eventLoop.execute {
                    logger.debug("timeout occured! \(self.id)")
                    self.websocket.close(
                        code: .unknown(1006),
                        reason: LCLWebSocketError.websocketTimeout.description,
                        promise: nil
                    )
                }
            }

            _ = self.timerTracker.withLockedValue {
                logger.debug("timer tracker size: \($0.count)")
                return $0.removeValue(forKey: self.id)
            }
        }
    }
}

extension WebSocket {

    /// The type of the WebSocket instance.
    public enum WebSocketType: Sendable, Equatable {
        /// WebSocket client
        case client

        /// WebSocket server
        case server
    }

    private enum WebSocketState: Int, Sendable {
        case connecting = 0
        case open = 1
        case closing = 2
        case closed = 3
    }
}

extension WebSocket {

    /// A collection of information that the WebSocket uses to make the connection
    public struct ConnectionInfo: Sendable {

        /// The URL that the WebSocket client connects to
        let url: URLComponents?

        /// The protocol, "ws" or "wss", that the WebSocket follows
        let `protocol`: String?

        //        let extensions: [any WebSocketExtensionOption]?

        init(url: URLComponents? = nil, protocol: String? = nil) {
            self.url = url
            self.protocol = `protocol`
            //            self.extensions = extensions
        }
    }
}
