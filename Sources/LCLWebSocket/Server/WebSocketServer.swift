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
    private let isMultiThreadedEventLoop: Bool

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
        self.isMultiThreadedEventLoop = self.eventloopGroup is MultiThreadedEventLoopGroup
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
    ///   - supportedExtensions: the WebSocket extensions that this server supports.
    /// - Returns: a `EventLoopFuture` that will be resolved once the server is closed.
    public func listen(
        host: String,
        port: Int,
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption] = []
    ) -> EventLoopFuture<Void> {
        do {
            let resolvedAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
            return self.listen(
                to: resolvedAddress,
                configuration: configuration,
                supportedExtensions: supportedExtensions
            )
        } catch {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }
    }

    /// Let the WebSocket server bind and listen to the given address, using the provided configuration.
    ///
    /// - Parameters:
    ///   - address: The address to listen to
    ///   - configuration: the configuration used to configure the WebSocket server
    ///   - supportedExtensions: the WebSocket extensions that this server supports.
    /// - Returns: a `EventLoopFuture` that will be resolved once the server is closed.
    public func listen(
        to address: SocketAddress,
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption] = []
    ) -> EventLoopFuture<Void> {
        self.makeBootstrapAndBind(with: configuration, resolvedAddress: address) { channel in
            logger.info("Servicing new connection: \(String(describing: channel.remoteAddress))")
            do {
                try self.initializeChildChannel(using: configuration, on: channel)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            return self.configureWebSocketServerUpgrade(
                on: channel,
                configuration: configuration,
                supportedExtensions: supportedExtensions
            )
        }.flatMap { channel in
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
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption]
    ) -> EventLoopFuture<Void> {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: configuration.maxFrameSize,
            automaticErrorHandling: false,
            shouldUpgrade: self.serverUpgradeConfiguration.shouldUpgrade
        ) { channel, _ in

            let acceptedExtensions: [any WebSocketExtensionOption]
            do {
                // remove all handlers added by LCLWebSocketServer
                let methodValidationHandler = try channel.pipeline.syncOperations.handler(
                    type: HTTPRequestMethodValidationHandler.self
                )
                let requestErrorHandler = try channel.pipeline.syncOperations.handler(
                    type: HTTPServerRequestErrorHandler.self
                )
                let upgradeHandler = try channel.pipeline.syncOperations.handler(
                    type: HTTPServerUpgradeHandler.self
                )
                let extensionHandler = try channel.pipeline.syncOperations.handler(
                    type: WebSocketExtensionNegotiationRequestHandler.self
                )
                acceptedExtensions = extensionHandler.acceptedExtensions

                channel.pipeline.syncOperations.removeHandler(methodValidationHandler, promise: nil)
                channel.pipeline.syncOperations.removeHandler(requestErrorHandler, promise: nil)
                channel.pipeline.syncOperations.removeHandler(upgradeHandler, promise: nil)
                channel.pipeline.syncOperations.removeHandler(extensionHandler, promise: nil)

            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            let url = channel.remoteAddress?.ipAddress.flatMap { URLComponents(string: $0) }
            let websocket = WebSocket(
                channel: channel,
                type: .server,
                configuration: configuration,
                connectionInfo: .init(url: url)
            )
            websocket.onPing(self._onPing)
            websocket.onPong(self._onPong)
            websocket.onText(self._onText)
            websocket.onBinary(self._onBinary)
            websocket.onClosing(self._onClosing)

            do {
                try channel.syncOptions?.setOption(
                    .writeBufferWaterMark,
                    value: .init(
                        low: configuration.writeBufferWaterMarkLow,
                        high: configuration.writeBufferWaterMarkHigh
                    )
                )
                try channel.pipeline.syncOperations.addHandler(
                    WebSocketHandler(websocket: websocket, configuration: configuration, extensions: acceptedExtensions)
                )
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
            let httpServerUpgradeHandler = try channel.pipeline.syncOperations.handler(
                type: HTTPServerUpgradeHandler.self
            )
            try channel.pipeline.syncOperations.addHandler(
                HTTPRequestMethodValidationHandler(allowedMethods: [.GET]),
                position: .before(httpServerUpgradeHandler)
            )

            try channel.pipeline.syncOperations.addHandler(
                WebSocketExtensionNegotiationRequestHandler(supportedExtensions: supportedExtensions),
                position: .before(httpServerUpgradeHandler)
            )
            try channel.pipeline.syncOperations.addHandler(HTTPServerRequestErrorHandler(), position: .last)

            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
}

extension WebSocketServer {

    private func initializeChildChannel(using configuration: LCLWebSocket.Configuration, on channel: Channel) throws {
        // enable tls if configuration is provided
        if let tlsConfiguration = configuration.tlsConfiguration {
            guard let sslContext = try? NIOSSLContext(configuration: tlsConfiguration) else {
                throw LCLWebSocketError.tlsInitializationFailed
            }
            let sslServerHandler = NIOSSLServerHandler(context: sslContext)
            try channel.pipeline.syncOperations.addHandler(sslServerHandler)
        }
    }

    private func makeBootstrapAndBind(
        with configuration: LCLWebSocket.Configuration,
        resolvedAddress: SocketAddress,
        childChannelInitializer: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {

        func makeServerBootstrap() -> EventLoopFuture<Channel> {
            ServerBootstrap(group: self.eventloopGroup)
                .serverChannelOption(
                    .socketOption(.so_reuseaddr),
                    value: SocketOptionValue(configuration.socketReuseAddress ? 1 : 0)
                )
                .serverChannelOption(
                    .tcpOption(.tcp_nodelay),
                    value: SocketOptionValue(configuration.socketTcpNoDelay ? 1 : 0)
                )
                .childChannelOption(
                    .socketOption(.so_reuseaddr),
                    value: SocketOptionValue(configuration.socketReuseAddress ? 1 : 0)
                )
                .childChannelOption(
                    .tcpOption(.tcp_nodelay),
                    value: SocketOptionValue(configuration.socketTcpNoDelay ? 1 : 0)
                )
                .childChannelOption(.socketOption(.so_sndbuf), value: configuration.socketSendBufferSize)
                .childChannelOption(.socketOption(.so_rcvbuf), value: configuration.socketReceiveBufferSize)
                .serverChannelInitializer { channel in
                    logger.info("Server is listening on \(resolvedAddress)")

                    // bind to selected device, if any
                    if let deviceName = configuration.deviceName,
                        let device = findDevice(with: deviceName, protocol: resolvedAddress.protocol)
                    {
                        logger.debug("deviceName \(deviceName), device \(device)")
                        return bindTo(device, on: channel)
                    }

                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .childChannelInitializer(childChannelInitializer)
                .bind(to: resolvedAddress)
        }

        #if canImport(Network)
        func makeNIOTSListenerBootstrap() -> EventLoopFuture<Channel> {

            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.connectionTimeout = Int(configuration.connectionTimeout.seconds)
            tcpOptions.noDelay = configuration.socketTcpNoDelay

            return NIOTSListenerBootstrap(group: self.eventloopGroup)
                .tcpOptions(tcpOptions)
                .serverChannelOption(
                    .socketOption(.so_reuseaddr),
                    value: SocketOptionValue(configuration.socketReuseAddress ? 1 : 0)
                )
                .childChannelOption(
                    .socketOption(.so_reuseaddr),
                    value: SocketOptionValue(configuration.socketReuseAddress ? 1 : 0)
                )
                .serverChannelInitializer { channel in
                    logger.info("Server is listening on \(resolvedAddress)")

                    // bind to selected device, if any
                    if let deviceName = configuration.deviceName,
                        let device = findDevice(with: deviceName, protocol: resolvedAddress.protocol)
                    {
                        logger.debug("deviceName \(deviceName), device \(device)")
                        return bindTo(device, on: channel)
                    }

                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .childChannelInitializer(childChannelInitializer)
                .bind(to: resolvedAddress)
        }
        #endif

        #if canImport(Network)
        if self.isMultiThreadedEventLoop {
            return makeServerBootstrap()
        } else {
            return makeNIOTSListenerBootstrap()
        }
        #else
        return makeServerBootstrap()
        #endif

    }
}

#if !canImport(Darwin) || swift(>=5.10)
extension WebSocketServer {

    /// Let the WebSocket server bind and listen to the given address, using the provided configuration.
    ///
    /// - Parameters:
    ///   - address: The address to listen to
    ///   - configuration: the configuration used to configure the WebSocket server
    /// - Returns: a `EventLoopFuture` that will be resolved once the server is closed.
    ///
    /// - Note: this is functionally the same as `listen(to:configuration:)`. But this function relies on infrastructures that
    /// is available only on Swift >= 5.10
    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, *)
    public func typedListen(
        to address: SocketAddress,
        configuration: LCLWebSocket.Configuration
    ) -> EventLoopFuture<Void> {
        self.makeBootstrapAndBind(with: configuration, resolvedAddress: address) { channel in
            logger.info("Servicing new connection: \(String(describing: channel.remoteAddress))")
            do {
                try self.initializeChildChannel(using: configuration, on: channel)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            return self.configureTypedWebSocketServerUpgrade(on: channel, configuration: configuration)
        }.flatMap { channel in
            channel.closeFuture
        }
    }

    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, *)
    private func configureTypedWebSocketServerUpgrade(
        on channel: Channel,
        configuration: LCLWebSocket.Configuration
    ) -> EventLoopFuture<Void> {
        let upgrader: NIOTypedWebSocketServerUpgrader<UpgradeResult> = NIOTypedWebSocketServerUpgrader(
            maxFrameSize: configuration.maxFrameSize,
            shouldUpgrade: self.serverUpgradeConfiguration.shouldUpgrade
        ) { channel, httpRequestHead in

            let acceptedExtensions: [any WebSocketExtensionOption]
            do {
                // remove all handlers added by LCLWebSocketServer
                let methodValidationHandler = try channel.pipeline.syncOperations.handler(
                    type: HTTPRequestMethodValidationHandler.self
                )
                let requestErrorHandler = try channel.pipeline.syncOperations.handler(
                    type: HTTPServerRequestErrorHandler.self
                )
                let upgradeHandler = try channel.pipeline.syncOperations.handler(
                    type: HTTPServerUpgradeHandler.self
                )
                let extensionHandler = try channel.pipeline.syncOperations.handler(
                    type: WebSocketExtensionNegotiationRequestHandler.self
                )
                acceptedExtensions = extensionHandler.acceptedExtensions

                channel.pipeline.syncOperations.removeHandler(methodValidationHandler, promise: nil)
                channel.pipeline.syncOperations.removeHandler(requestErrorHandler, promise: nil)
                channel.pipeline.syncOperations.removeHandler(upgradeHandler, promise: nil)
                channel.pipeline.syncOperations.removeHandler(extensionHandler, promise: nil)

            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            let url = channel.remoteAddress?.ipAddress.flatMap { URLComponents(string: $0) }

            let websocket = WebSocket(
                channel: channel,
                type: .server,
                configuration: configuration,
                connectionInfo: .init(url: url)
            )
            websocket.onPing(self._onPing)
            websocket.onPong(self._onPong)
            websocket.onText(self._onText)
            websocket.onBinary(self._onBinary)
            do {
                try channel.syncOptions?.setOption(
                    .writeBufferWaterMark,
                    value: .init(
                        low: configuration.writeBufferWaterMarkLow,
                        high: configuration.writeBufferWaterMarkHigh
                    )
                )
                try channel.pipeline.syncOperations.addHandler(
                    WebSocketHandler(websocket: websocket, configuration: configuration, extensions: acceptedExtensions)
                )
                return channel.eventLoop.makeSucceededFuture(UpgradeResult.websocket)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        let serverUpgradeConfig = NIOTypedHTTPServerUpgradeConfiguration(upgraders: [upgrader]) { channel in
            logger.error("server upgrade failed")
            return channel.eventLoop.makeSucceededFuture(UpgradeResult.notUpgraded(nil))
        }

        do {
            let upgradeResult: EventLoopFuture<UpgradeResult> = try channel.pipeline.syncOperations
                .configureUpgradableHTTPServerPipeline(
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
                let responseHead = makeResponse(with: .methodNotAllowed)
                context.channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
                context.channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
                context.fireErrorCaught(LCLWebSocketError.methodNotAllowed)
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
            context.channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
            context.channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)

            // FIXME: this line will cause crash when using NIOListeningBootstrap from NIOTransportService with ioOnClosedChannel.
            context.close(mode: .all, promise: nil)
        }
    }
}
