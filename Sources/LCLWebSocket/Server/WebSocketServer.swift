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

import Atomics
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

#if canImport(Network)
import Network
import NIOTransportServices
#endif

/// A WebSocket server that handles requests from the client.
/// Each client connection will be dispatched and handled by a child `Channel`
///
/// - Note: The server instance is long running unless manually closed and torn down.
public struct WebSocketServer: Sendable, LCLWebSocketListenable {

    enum UpgradeResult {
        case notUpgraded(Error?)
        case websocket
    }

    private let eventloopGroup: EventLoopGroup
    private let serverUpgradeConfiguration: WebSocketServerUpgradeConfiguration
    private var _onOpen: (@Sendable (WebSocket) -> Void)?
    private var _onPing: (@Sendable (WebSocket, ByteBuffer) -> Void)?
    private var _onPong: (@Sendable (WebSocket, ByteBuffer) -> Void)?
    private var _onText: (@Sendable (WebSocket, String) -> Void)?
    private var _onBinary: (@Sendable (WebSocket, ByteBuffer) -> Void)?
    private var _onClosing: (@Sendable (WebSocketErrorCode?, String?) -> Void)?
    private var _onClosed: (@Sendable () -> Void)?
    private var _onError: (@Sendable (Error) -> Void)?

    private let isShutdown: ManagedAtomic<Bool>

    /// Initialize a `WebSocketServer` instance on the given `EventLoopGroup` using the provided `serverConfiguration`
    ///
    /// - Parameters:
    ///     - on: the `EventLoopGroup` that this server will be running on
    ///     - serverUpgradeConfiguration: the server upgrade configuration that will be used to configure the server.
    init(
        on eventloopGroup: any EventLoopGroup,
        serverUpgradeConfiguration: WebSocketServerUpgradeConfiguration = .defaultConfiguration
    ) {
        self.eventloopGroup = eventloopGroup
        self.serverUpgradeConfiguration = serverUpgradeConfiguration
        self.isShutdown = ManagedAtomic(false)
    }

    public mutating func onOpen(_ callback: (@Sendable (WebSocket) -> Void)?) {
        self._onOpen = callback
    }

    public mutating func onPing(_ onPing: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onPing = onPing
    }

    public mutating func onPong(_ onPong: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onPong = onPong
    }

    public mutating func onText(_ onText: (@Sendable (WebSocket, String) -> Void)?) {
        self._onText = onText
    }

    public mutating func onBinary(_ onBinary: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onBinary = onBinary
    }

    public mutating func onClosing(_ callback: (@Sendable (WebSocketErrorCode?, String?) -> Void)?) {
        self._onClosing = callback
    }

    public mutating func onClosed(_ callback: (@Sendable () -> Void)?) {
        self._onClosed = callback
    }

    public mutating func onError(_ onError: (@Sendable (any Error) -> Void)?) {
        self._onError = onError
    }

    /// Let the WebSocket server bind and listen to the given address, using the provided configuration.
    /// - Parameters:
    ///   - host: the host IP address to listen to
    ///   - port: the port at which the WebSocket server will be listening on
    ///   - configuration: the configuration used to configure the WebSocket server
    /// - Returns: a `EventLoopFuture` that will be resolved once the server is closed.
    public func listen(host: String, port: Int, configuration: LCLWebSocket.Configuration) -> EventLoopFuture<Void> {
        do {
            let resolvedAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
            return self.listen(to: resolvedAddress, configuration: configuration)
        } catch {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }
    }

    /// Let the WebSocket server bind and listen to the given address, using the provided configuration.
    ///
    /// - Parameters:
    ///   - address: The address to listen to
    ///   - configuration: the configuration used to configure the WebSocket server
    /// - Returns: a `EventLoopFuture` that will be resolved once the server is closed.
    public func listen(to address: SocketAddress, configuration: LCLWebSocket.Configuration) -> EventLoopFuture<Void> {
        self.makeBootstrapAndBind(with: configuration, resolvedAddress: address) { channel in
            logger.debug("child channel: \(channel)")
            if let tlsConfiguration = configuration.tlsConfiguration {
                guard let sslContext = try? NIOSSLContext(configuration: tlsConfiguration) else {
                    return channel.eventLoop.makeFailedFuture(LCLWebSocketError.tlsInitializationFailed)
                }
                let sslServerHandler = NIOSSLServerHandler(context: sslContext)
                do {
                    try channel.pipeline.syncOperations.addHandler(sslServerHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

            return self.configureWebSocketServerUpgrade(on: channel, configuration: configuration)
        }
        .flatMap { channel in
            channel.closeFuture
        }
    }

    /// Shutdown the WebSocket client.
    ///
    /// - Parameters:
    ///     - callback: callback function that will be invoked when an error occurred during shutdown
    public func shutdown(_ callback: @escaping ((Error?) -> Void)) {
        let (exchanged, _) = self.isShutdown.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        if exchanged {
            self.eventloopGroup.shutdownGracefully(callback)
        } else {
            logger.info("WebSocket server already shutdown")
        }
    }

    private func configureWebSocketServerUpgrade(
        on channel: Channel,
        configuration: LCLWebSocket.Configuration
    ) -> EventLoopFuture<Void> {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: configuration.maxFrameSize,
            automaticErrorHandling: false,
            shouldUpgrade: self.serverUpgradeConfiguration.shouldUpgrade
        ) { channel, httpRequestHead in
            let websocket = WebSocket(
                channel: channel,
                type: .server,
                configuration: configuration,
                connectionInfo: nil
            )
            websocket.onPing(self._onPing)
            websocket.onPong(self._onPong)
            websocket.onText(self._onText)
            websocket.onBinary(self._onBinary)
            websocket.onClosing(self._onClosing)

            do {

                // remove all handlers added by LCLWebSocketServer
                let methodValidationHandlerCtx = try channel.pipeline.syncOperations.context(
                    handlerType: HTTPRequestMethodValidationHandler.self
                )
                let requestErrorHandlerCtx = try channel.pipeline.syncOperations.context(
                    handlerType: HTTPServerRequestErrorHandler.self
                )
                let upgradeHandlerCtx = try channel.pipeline.syncOperations.context(
                    handlerType: HTTPServerUpgradeHandler.self
                )

                _ = channel.pipeline.syncOperations.removeHandler(context: methodValidationHandlerCtx)
                _ = channel.pipeline.syncOperations.removeHandler(context: requestErrorHandlerCtx)
                _ = channel.pipeline.syncOperations.removeHandler(context: upgradeHandlerCtx)

                try channel.syncOptions?.setOption(
                    .writeBufferWaterMark,
                    value: .init(
                        low: configuration.writeBufferWaterMarkLow,
                        high: configuration.writeBufferWaterMarkHigh
                    )
                )
                try channel.pipeline.syncOperations.addHandlers([
                    NIOWebSocketFrameAggregator(
                        minNonFinalFragmentSize: configuration.minNonFinalFragmentSize,
                        maxAccumulatedFrameCount: configuration.maxAccumulatedFrameCount,
                        maxAccumulatedFrameSize: configuration.maxAccumulatedFrameSize
                    ),
                    WebSocketHandler(websocket: websocket),
                ])
                self._onOpen?(websocket)
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        let serverUpgradeConfig = NIOHTTPServerUpgradeConfiguration(
            upgraders: [upgrader],
            completionHandler: { channel in }
        )
        do {
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withServerUpgrade: serverUpgradeConfig)
            let protocolErrorHandler = try channel.pipeline.syncOperations.handler(
                type: HTTPServerProtocolErrorHandler.self
            )
            try channel.pipeline.syncOperations.addHandler(
                HTTPRequestMethodValidationHandler(allowedMethods: [.GET]),
                position: .after(protocolErrorHandler)
            )
            try channel.pipeline.syncOperations.addHandler(HTTPServerRequestErrorHandler(), position: .last)
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
}

extension WebSocketServer {
    private func makeBootstrapAndBind(
        with configuration: LCLWebSocket.Configuration,
        resolvedAddress: SocketAddress,
        childChannelInitializer: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        if self.eventloopGroup is MultiThreadedEventLoopGroup {
            return ServerBootstrap(group: self.eventloopGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelInitializer { channel in
                    print("parent channel: \(channel)")
                    if let socketSendBufferSize = configuration.socketSendBufferSize,
                        let syncOptions = channel.syncOptions
                    {
                        do {
                            try syncOptions.setOption(.socketOption(.so_sndbuf), value: socketSendBufferSize)
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }

                    if let socketReceiveBuffer = configuration.socketReceiveBufferSize,
                        let syncOptions = channel.syncOptions
                    {
                        do {
                            try syncOptions.setOption(.socketOption(.so_rcvbuf), value: socketReceiveBuffer)
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }

                    // bind to selected device, if any
                    if let deviceName = configuration.deviceName,
                        let device = findDevice(with: deviceName, protocol: resolvedAddress.protocol)
                    {
                        do {
                            try bindTo(device: device, on: channel)
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }

                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer(childChannelInitializer)
                .bind(to: resolvedAddress)
        } else {
            return NIOTSListenerBootstrap(group: self.eventloopGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelInitializer { channel in
                    print("parent channel: \(channel)")
                    if let socketSendBufferSize = configuration.socketSendBufferSize,
                        let syncOptions = channel.syncOptions
                    {
                        do {
                            try syncOptions.setOption(.socketOption(.so_sndbuf), value: socketSendBufferSize)
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }

                    if let socketReceiveBuffer = configuration.socketReceiveBufferSize,
                        let syncOptions = channel.syncOptions
                    {
                        do {
                            try syncOptions.setOption(.socketOption(.so_rcvbuf), value: socketReceiveBuffer)
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }

                    // bind to selected device, if any
                    if let deviceName = configuration.deviceName,
                        let device = findDevice(with: deviceName, protocol: resolvedAddress.protocol)
                    {
                        do {
                            try bindTo(device: device, on: channel)
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }

                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer(childChannelInitializer)
                .bind(to: resolvedAddress)
        }
    }
}

#if !canImport(Darwin) || swift(>=5.10)
extension WebSocketServer {
    //    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, visionOS 1.0, *)
    //    public func listen(
    //        to host: String,
    //        port: Int,
    //        configuration: LCLWebSocket.Configuration
    //    ) throws -> EventLoopFuture<Void> {
    //        let addr = try SocketAddress(ipAddress: host, port: port)
    //        return self.listen(to: addr, configuration: configuration)
    //    }

    /// Let the WebSocket server bind and listen to the given address, using the provided configuration.
    ///
    /// - Parameters:
    ///   - address: The address to listen to
    ///   - configuration: the configuration used to configure the WebSocket server
    /// - Returns: a `EventLoopFuture` that will be resolved once the server is closed.
    ///
    /// - Note: this is functionally the same as `listen(to:configuration:)`. But this function relies on infrastructures that
    /// is available only on Swift >= 5.10
    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, visionOS 1.0, *)
    public func typedListen(
        to address: SocketAddress,
        configuration: LCLWebSocket.Configuration
    ) -> EventLoopFuture<Void> {
        self.makeBootstrapAndBind(with: configuration, resolvedAddress: address) { channel in
            // enable tls if configuration is provided
            logger.debug("child channel: \(channel)")
            if let tlsConfiguration = configuration.tlsConfiguration {
                guard let sslContext = try? NIOSSLContext(configuration: tlsConfiguration) else {
                    return channel.eventLoop.makeFailedFuture(LCLWebSocketError.tlsInitializationFailed)
                }
                let sslServerHandler = NIOSSLServerHandler(context: sslContext)
                do {
                    try channel.pipeline.syncOperations.addHandler(sslServerHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

            return self.configureTypedWebSocketServerUpgrade(on: channel, configuration: configuration)
        }
        .flatMap { channel in
            channel.closeFuture
        }
    }

    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, visionOS 1.0, *)
    private func configureTypedWebSocketServerUpgrade(
        on channel: Channel,
        configuration: LCLWebSocket.Configuration
    ) -> EventLoopFuture<Void> {
        let upgrader = NIOTypedWebSocketServerUpgrader(
            maxFrameSize: configuration.maxFrameSize,
            shouldUpgrade: self.serverUpgradeConfiguration.shouldUpgrade
        ) { channel, httpRequestHead in
            let websocket = WebSocket(
                channel: channel,
                type: .server,
                configuration: configuration,
                connectionInfo: nil
            )
            websocket.onPing(self._onPing)
            websocket.onPong(self._onPong)
            websocket.onText(self._onText)
            websocket.onBinary(self._onBinary)
            do {

                // remove all handlers added by LCLWebSocketServer
                let methodValidationHandlerCtx = try channel.pipeline.syncOperations.context(
                    handlerType: HTTPRequestMethodValidationHandler.self
                )
                let requestErrorHandlerCtx = try channel.pipeline.syncOperations.context(
                    handlerType: HTTPServerRequestErrorHandler.self
                )
                let upgradeHandlerCtx = try channel.pipeline.syncOperations.context(
                    handlerType: HTTPServerUpgradeHandler.self
                )

                _ = channel.pipeline.syncOperations.removeHandler(context: methodValidationHandlerCtx)
                _ = channel.pipeline.syncOperations.removeHandler(context: requestErrorHandlerCtx)
                _ = channel.pipeline.syncOperations.removeHandler(context: upgradeHandlerCtx)

                try channel.syncOptions?.setOption(
                    .writeBufferWaterMark,
                    value: .init(
                        low: configuration.writeBufferWaterMarkLow,
                        high: configuration.writeBufferWaterMarkHigh
                    )
                )
                try channel.pipeline.syncOperations.addHandlers([
                    NIOWebSocketFrameAggregator(
                        minNonFinalFragmentSize: configuration.minNonFinalFragmentSize,
                        maxAccumulatedFrameCount: configuration.maxAccumulatedFrameCount,
                        maxAccumulatedFrameSize: configuration.maxAccumulatedFrameSize
                    ),
                    WebSocketHandler(websocket: websocket),
                ])
                print(channel.pipeline.debugDescription, channel)
                return channel.eventLoop.makeSucceededFuture(UpgradeResult.websocket)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        let serverUpgradeConfig = NIOTypedHTTPServerUpgradeConfiguration(upgraders: [upgrader]) { channel in
            logger.debug("server upgrade failed")
            return channel.eventLoop.makeSucceededFuture(UpgradeResult.notUpgraded(nil))
        }

        do {
            let upgradeResult = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                configuration: .init(upgradeConfiguration: serverUpgradeConfig)
            )
            return upgradeResult.flatMap { result in
                switch result {
                case .websocket:
                    return channel.eventLoop.makeSucceededVoidFuture()
                case .notUpgraded(.some(let error)):
                    return channel.eventLoop.makeFailedFuture(error)
                case .notUpgraded(.none):
                    return channel.eventLoop.makeFailedFuture(LCLWebSocketError.notUpgraded)
                }
            }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
}
#endif

extension WebSocketServer {

    // respond with status code and the body string back to the client
    // Connection: close and Content-Length: 0 will be included automatically
    private static func makeResponse(
        with status: HTTPResponseStatus,
        additionalHeaders: [String: String]? = nil
    ) -> HTTPResponseHead {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")

        if additionalHeaders != nil {
            for (key, val) in additionalHeaders! {
                headers.add(name: key, value: val)
            }
        }

        return HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    }

    /// A `ChannelHandler` that validate the HTTP Request method given the allow list of methods.
    private final class HTTPRequestMethodValidationHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias InboundOut = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private enum HTTPRequestMethodValidationStateMachine {
            case ok
            case invalidMethod
        }

        private let allowedMethods: [HTTPMethod]
        private var state: HTTPRequestMethodValidationStateMachine

        init(allowedMethods: [HTTPMethod]) {
            self.allowedMethods = allowedMethods
            self.state = .ok
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let requestPart = self.unwrapInboundIn(data)
            switch (requestPart, self.state) {
            case (.head, .invalidMethod):
                preconditionFailure(
                    "HTTPRequestMethodValidationHandler is not in a valid state while receiving http request head. \(self.state)"
                )
            case (.head(let head), .ok):
                if !allowedMethods.contains(head.method) {
                    self.state = .invalidMethod
                    logger.error("Request method is not valid. Received: \(head.method). Expected: \(allowedMethods)")
                } else {
                    context.fireChannelRead(data)
                }
            case (.body, .ok):
                context.fireChannelRead(data)
            case (.body, .invalidMethod):
                ()
            case (.end, .ok):
                context.fireChannelRead(data)
            case (.end, .invalidMethod):
                let resposneHead = makeResponse(with: .methodNotAllowed)
                context.channel.write(self.wrapOutboundOut(.head(resposneHead)), promise: nil)
                context.channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                context.fireErrorCaught(LCLWebSocketError.methodNotAllowed)
                context.close(mode: .all, promise: nil)
            }
        }
    }

    /// A `ChannelHandler` that handles HTTP request error during upgrade
    private final class HTTPServerRequestErrorHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias InboundOut = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private enum HTTPServerRequestErrorHandlerStateMachine {
            case ok
            case error(Error)
            case done
        }

        private var state: HTTPServerRequestErrorHandlerStateMachine = .ok

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let request = self.unwrapInboundIn(data)
            switch (request, self.state) {
            case (.end, .error(let err)):
                // close the channel
                self.closeChannel(for: err, with: context)
            default:
                context.fireChannelRead(data)
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            switch self.state {
            case .ok:
                self.state = .error(error)
                logger.error("error caught in during upgrade: \(error)")
                context.fireErrorCaught(error)
            case .done:
                self.closeChannel(for: error, with: context)
            case .error:
                preconditionFailure("Channel should already be closed. But it is still receiving error: \(error)")
            }
        }

        private func closeChannel(for error: Error, with context: ChannelHandlerContext) {
            let responseHead: HTTPResponseHead
            if (error as? NIOWebSocketUpgradeError) == .unsupportedWebSocketTarget {
                responseHead = makeResponse(with: .badRequest)
            } else {
                logger.error("unknown error caught during upgrade: \(error)")
                responseHead = makeResponse(with: .internalServerError)
            }
            logger.debug("closing channel due to error \(error). response head \(responseHead)")
            context.channel.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            context.channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.close(mode: .all, promise: nil)
        }
    }
}
