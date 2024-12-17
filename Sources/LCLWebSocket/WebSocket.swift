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
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public final class WebSocket: Sendable {

    typealias TimerTracker = [String: NIOScheduledCallback]
    private static let pingIDLength = 36

    public let channel: Channel
    private let type: WebSocketType
    private let configuration: LCLWebSocket.Configuration
    private let state: NIOLockedValueBox<WebSocketState>
    private let timerTracker: NIOLockedValueBox<TimerTracker>
    private let connectionInfo: ConnectionInfo?

    // MARK: callbacks
    private let _onPing: NIOLoopBoundBox<(@Sendable (ByteBuffer) -> Void)?>
    private let _onPong: NIOLoopBoundBox<(@Sendable (ByteBuffer) -> Void)?>
    private let _onText: NIOLoopBoundBox<(@Sendable (String) -> Void)?>
    private let _onBinary: NIOLoopBoundBox<(@Sendable (ByteBuffer) -> Void)?>

    public init(
        channel: Channel,
        type: WebSocketType,
        configuration: LCLWebSocket.Configuration,
        connectionInfo: ConnectionInfo?
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
        self.connectionInfo = connectionInfo
        if self.configuration.autoPingConfiguration.keepAlive {
            self.scheduleNextPing()
        }
    }

    public var url: String? {
        self.connectionInfo?.url.description
    }
    public var bufferedAmount: EventLoopFuture<Int> {
        self.channel.getOption(.bufferedWritableBytes)
    }

    public var `protocol`: String? {
        self.connectionInfo?.protocol
    }

    public func onPing(_ callback: (@Sendable (ByteBuffer) -> Void)?) {
        self.channel.eventLoop.execute {
            self._onPing.value = callback
        }
    }

    public func onPong(_ callback: (@Sendable (ByteBuffer) -> Void)?) {
        self.channel.eventLoop.execute {
            self._onPong.value = callback
        }
    }

    public func onText(_ callback: (@Sendable (String) -> Void)?) {
        self.channel.eventLoop.execute {
            self._onText.value = callback
        }
    }

    public func onBinary(_ callback: (@Sendable (ByteBuffer) -> Void)?) {
        self.channel.eventLoop.execute {
            self._onBinary.value = callback
        }
    }

    public func send(
        _ buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        // TODO: if the channel is not active, abort the operation
        if !self.channel.isActive {
            promise?.fail(LCLWebSocketError.channelNotActive)
            return
        }

        self.state.withLockedValue { state in
            switch state {
            case .open:
                let frame = WebSocketFrame(
                    fin: fin,
                    opcode: opcode,
                    maskKey: self.makeMaskingKey(),
                    data: buffer
                )
                self.channel.writeAndFlush(frame, promise: promise)
            default:
                promise?.fail(LCLWebSocketError.websocketNotConnected)
            }
        }
    }

    public func send(
        _ buffer: ByteBuffer,
        opcode: WebSocketOpcode,
        fin: Bool = true
    ) -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.send(buffer, opcode: opcode, fin: fin, promise: promise)
        return promise.futureResult
    }

    public func close(
        code: WebSocketErrorCode = .normalClosure,
        reason: String? = nil,
        promise: EventLoopPromise<Void>? = nil
    ) {
        // TODO: skip if already closed or closing
        if !self.channel.isActive {
            promise?.fail(LCLWebSocketError.channelNotActive)
            print("channel is not active")
            return
        }

        self.state.withLockedValue { state in
            print("websocket state: \(state)")
            switch state {
            case .closed:
                // TODO: probably close the channel?
                self.channel.close(mode: .all, promise: promise)
            case .closing:
                state = .closed
                promise?.succeed(())
            case .open:
                state = .closing
                var codeToSend = UInt16(webSocketErrorCode: code)
                if codeToSend == 1005 || codeToSend == 1006 {
                    codeToSend = UInt16(webSocketErrorCode: .normalClosure)
                }

                var buffer = channel.allocator.buffer(capacity: 125)
                buffer.writeInteger(codeToSend)

                if let reason = reason {
                    guard reason.utf8.count <= 123 else {
                        promise?.fail(LCLWebSocketError.closeReasonTooLong)
                        return
                    }
                    buffer.writeString(reason)
                }

                let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
                self.channel.writeAndFlush(frame, promise: promise)
            default:
                promise?.fail(LCLWebSocketError.channelNotActive)
            }
        }
    }

    public func close(
        code: WebSocketErrorCode = .normalClosure,
        reason: String? = nil
    ) -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.close(code: code, reason: reason, promise: promise)
        return promise.futureResult
    }

    public func ping(data: ByteBuffer = .init(), promise: EventLoopPromise<Void>? = nil) {
        // TODO: check if it already received a Close frame
        if !self.channel.isActive {
            promise?.fail(LCLWebSocketError.channelNotActive)
            return
        }

        switch self.state.withLockedValue({ $0 }) {
        case .open:
            self.send(data, opcode: .ping, fin: true, promise: promise)
        case .closing, .closed:
            promise?.fail(LCLWebSocketError.websocketAlreadyClosed)
        default:
            promise?.fail(LCLWebSocketError.websocketNotConnected)
        }
    }

    public func pong(data: ByteBuffer = .init(), promise: EventLoopPromise<Void>? = nil) {
        // TODO: check if it already received a Close frame
        if !self.channel.isActive {
            promise?.fail(LCLWebSocketError.channelNotActive)
            return
        }

        self.state.withLockedValue { state in
            switch state {
            case .open:
                self.send(data, opcode: .pong, promise: promise)
            case .closing, .closed:
                promise?.fail(LCLWebSocketError.websocketAlreadyClosed)
            default:
                promise?.fail(LCLWebSocketError.websocketNotConnected)
            }
        }
    }

    public func handleFrame(_ frame: WebSocketFrame) {
        switch frame.opcode {
        case .binary:
            var data = frame.data
            if let maskKey = frame.maskKey {
                data.webSocketUnmask(maskKey)
            }

            self._onBinary.value?(data)
        case .text:
            var data = frame.data
            if let maskKey = frame.maskKey {
                data.webSocketUnmask(maskKey)
            }
            self._onText.value?(data.readString(length: data.readableBytes) ?? "")
        case .connectionClose:
            // if a previous close frame is received
            // if we have sent a close frame
            // we should not send more frame
            // mark the state as closed
            // if we have not sent a close frame
            // we send the close frame, with the same application data
            // if we are client, we have to mask the data

            switch self.state.withLockedValue({ $0 }) {
            case .closing:
                self.state.withLockedValue { $0 = .closed }
            case .closed:
                ()
            default:
                self.state.withLockedValue { $0 = .closing }
                self.send(frame.data, opcode: .connectionClose, promise: nil)
                self.state.withLockedValue { $0 = .closed }
            }
        case .continuation:
            preconditionFailure("continuation frame is filtered by swiftnio")
        case .ping:
            // TODO:
            if frame.fin {
                self.pong(data: frame.data)
                self._onPing.value?(frame.data)
            } else {
                // error: control frame should not be fragmented
                self.close(
                    code: .protocolError,
                    reason: LCLWebSocketError.controlFrameShouldNotBeFragmented.description,
                    promise: nil
                )
            }
        case .pong:
            if frame.fin {
                // if there is no previous ping, unsolicited, a reponse is not expected
                self._onPong.value?(frame.data)
                var unmaskedData = frame.unmaskedData
                if frame.length == WebSocket.pingIDLength {
                    let id = unmaskedData.readString(length: unmaskedData.readableBytes)
                    self.timerTracker.withLockedValue { tracker in
                        if let id = id, let callback = tracker.removeValue(forKey: id) {
                            callback.cancel()
                        }
                    }
                }
            } else {
                self.close(
                    code: .protocolError,
                    reason: LCLWebSocketError.controlFrameShouldNotBeFragmented.description,
                    promise: nil
                )
            }
        default:
            ()
        }
    }

    private func scheduleNextPing() {
        self.channel.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(0),
            delay: self.configuration.autoPingConfiguration.pingInterval
        ) { repeatTask in
            // TODO: check if it already received a Close frame
            // TODO: check if the previous ping has a response
            // TODO: check if timeout occurs
            if !self.channel.isActive {
                print("channel is not active 111", "parent is active \(String(describing: self.channel.parent?.isActive))", "self is active: \(self.channel)")
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
                print("id: \(id)")
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

    private func makeMaskingKey() -> WebSocketMaskingKey? {
        switch self.type {
        case .client:
            return WebSocketMaskingKey.random()
        case .server:
            return nil
        }
    }
}

extension WebSocket {
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
                print("channel is still active. time out! \(self.id)")
                eventLoop.execute {
                    print("timeout occured! \(self.id)")
                    self.websocket.close(
                        code: .unknown(1006),
                        reason: LCLWebSocketError.websocketTimeout.description,
                        promise: nil
                    )
                }
            }
            
            _ = self.timerTracker.withLockedValue {
                print("timer tracker size: \($0.count)")
                return $0.removeValue(forKey: self.id)
            }
        }
    }
}

extension WebSocket {
    public enum WebSocketType: Sendable {
        case client
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
    public struct ConnectionInfo: Sendable {
        let url: URLComponents
        let `protocol`: String?
        // TODO: extension

        init(url: URLComponents, protocol: String? = nil) {
            self.url = url
            self.protocol = `protocol`
        }
    }
}
