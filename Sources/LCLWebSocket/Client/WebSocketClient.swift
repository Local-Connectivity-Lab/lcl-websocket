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
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

#if canImport(Network)
import NIOTransportServices
import Network
#endif

/// A WebSocket client that connects to the server and handles communications with the server.
public struct WebSocketClient: Sendable, LCLWebSocketListenable {

    private enum WebSocketUpgradeResult {
        case websocket(Channel)
        case notUpgraded(Error?)
    }

    public let eventloopGroup: any EventLoopGroup

    // MARK: callbacks
    private var _onOpen: (@Sendable (WebSocket) -> Void)?
    private var _onPing: (@Sendable (WebSocket, ByteBuffer) -> Void)?
    private var _onPong: (@Sendable (WebSocket, ByteBuffer) -> Void)?
    private var _onText: (@Sendable (WebSocket, String) -> Void)?
    private var _onBinary: (@Sendable (WebSocket, ByteBuffer) -> Void)?
    private var _onClosing: (@Sendable (WebSocketErrorCode?, String?) -> Void)?
    private var _onClosed: (@Sendable () -> Void)?
    private var _onError: (@Sendable (Error) -> Void)?

    private let isShutdown: ManagedAtomic<Bool>
    private let isMultiThreadedEventloop: Bool

    /// Initialize the `WebSocketClient` instance on the given `EventLoopGroup`
    ///
    /// - Parameters:
    ///     - on: the `EventLoopGroup` that the WebSocket client will be run on.
    init(on eventloopGroup: any EventLoopGroup) {
        self.eventloopGroup = eventloopGroup
        self.isShutdown = ManagedAtomic(false)
        self.isMultiThreadedEventloop = self.eventloopGroup is MultiThreadedEventLoopGroup
    }

    public mutating func onOpen(_ callback: (@Sendable (WebSocket) -> Void)?) {
        self._onOpen = callback
    }

    public mutating func onPing(_ callback: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onPing = callback
    }

    public mutating func onPong(_ callback: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onPong = callback
    }

    public mutating func onText(_ callback: (@Sendable (WebSocket, String) -> Void)?) {
        self._onText = callback
    }

    public mutating func onBinary(_ callback: (@Sendable (WebSocket, ByteBuffer) -> Void)?) {
        self._onBinary = callback
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

    /// Connect the WebSocket client to the given endpoint. The WebSocket client is configured using the provied configuration.
    /// While making the connection, the WebSocket client will be adding the addtional `headers`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoin to connect to in string format.
    ///   - headers: The additional headers that will be added to the HTTP Upgrade request, excluding WebSocket extension headers.
    ///   - configuration: The configuration that will be used to configure the WebSocket client.
    ///   - supportedExtensions: The WebSocket extensions that this client would like to negotiated with the server.
    /// - Returns: An `EventLoopFuture` that will be resolved once the connection is closed.
    public func connect(
        to endpoint: String,
        headers: [String: String] = [:],
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption] = []
    ) -> EventLoopFuture<Void> {
        guard let urlComponents = URLComponents(string: endpoint) else {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        return self.connect(
            to: urlComponents,
            headers: headers,
            configuration: configuration,
            supportedExtensions: supportedExtensions
        )
    }

    /// Connect the WebSocket client to the given endpoint. The WebSocket client is configured using the provied configuration.
    /// While making the connection, the WebSocket client will be adding the addtional `headers`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoin to connect to in `URL` format.
    ///   - headers: The additional headers that will be added to the HTTP Upgrade request, excluding WebSocket extension headers.
    ///   - configuration: The configuration that will be used to configure the WebSocket client.
    ///   - supportedExtensions: The WebSocket extensions that this client would like to negotiated with the server.
    /// - Returns: An `EventLoopFuture` that will be resolved once the connection is closed.
    public func connect(
        to endpoint: URL,
        headers: [String: String] = [:],
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption] = []
    ) -> EventLoopFuture<Void> {
        guard let urlComponents = URLComponents.init(url: endpoint, resolvingAgainstBaseURL: false) else {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        return self.connect(
            to: urlComponents,
            headers: headers,
            configuration: configuration,
            supportedExtensions: supportedExtensions
        )
    }

    /// Connect the WebSocket client to the given endpoint. The WebSocket client is configured using the provied configuration.
    /// While making the connection, the WebSocket client will be adding the addtional `headers`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoin to connect to.
    ///   - headers: The additional headers that will be added to the HTTP Upgrade request, excluding WebSocket extension headers.
    ///   - configuration: The configuration that will be used to configure the WebSocket client.
    ///   - supportedExtensions: The WebSocket extensions that this client would like to negotiated with the server.
    /// - Returns: An `EventLoopFuture` that will be resolved once the connection is closed.
    public func connect(
        to endpoint: URLComponents,
        headers: [String: String],
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption] = []
    ) -> EventLoopFuture<Void> {
        guard let s = endpoint.scheme, let scheme = WebSocketScheme(rawValue: s) else {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        guard let host = endpoint.host else {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        let port = endpoint.port ?? scheme.defaultPort
        let path = endpoint.path.isEmpty ? "/" : endpoint.path
        let query = endpoint.query ?? ""
        let uri = path + (query.isEmpty ? "" : "?" + query)

        logger.debug("host: \(host) port: \(port) uri: \(uri)")

        let resolvedAddress: SocketAddress
        do {
            resolvedAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
        } catch {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        return self.makeBootstrapAndConnect(
            with: configuration,
            resolvedAddress: resolvedAddress,
            channelInitializer: makeChannelInitializer(
                configuration: configuration,
                resolvedAddress: resolvedAddress,
                scheme: scheme,
                host: host
            )
        ).flatMap { channel in
            let upgrader = NIOWebSocketClientUpgrader(
                maxFrameSize: configuration.maxFrameSize,
                automaticErrorHandling: false
            ) { channel, httpResponse in
                let acceptedExtension: [any WebSocketExtensionOption]
                if supportedExtensions.isEmpty {
                    acceptedExtension = []
                } else {
                    do {
                        let extensionHandler = try channel.pipeline.syncOperations.handler(
                            type: WebSocketExtensionNegotiationResponseHandler.self
                        )
                        acceptedExtension = extensionHandler.acceptedExtensions

                        channel.pipeline.syncOperations.removeHandler(extensionHandler, promise: nil)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                let websocketConnectionInfo = WebSocket.ConnectionInfo(url: endpoint)
                let websocket = WebSocket(
                    channel: channel,
                    type: .client,
                    configuration: configuration,
                    connectionInfo: websocketConnectionInfo
                )
                websocket.onPing(self._onPing)
                websocket.onPong(self._onPong)
                websocket.onText(self._onText)
                websocket.onBinary(self._onBinary)
                websocket.onError(self._onError)
                websocket.onClosing(self._onClosing)
                websocket.onClosed(self._onClosed)

                do {
                    try channel.syncOptions?.setOption(
                        .writeBufferWaterMark,
                        value: .init(
                            low: configuration.writeBufferWaterMarkLow,
                            high: configuration.writeBufferWaterMarkHigh
                        )
                    )

                    try channel.pipeline.syncOperations.addHandlers(
                        WebSocketHandler(
                            websocket: websocket,
                            configuration: configuration,
                            extensions: acceptedExtension
                        )
                    )
                    self._onOpen?(websocket)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

            }

            var allHeaders = headers
            for ext in supportedExtensions {
                allHeaders[ext.httpHeader.name] = ext.httpHeader.val
            }

            let httpRequestHead = self.makeHTTPRequestHeader(uri: uri, host: host, port: port, headers: allHeaders)
            let httpUpgradeHandler = HTTPUpgradeHandler(httpRequest: httpRequestHead)

            let upgradeConfig = NIOHTTPClientUpgradeConfiguration(
                upgraders: [upgrader],
                completionHandler: { channel in
                    channel.pipeline.removeHandler(httpUpgradeHandler, promise: nil)
                }
            )

            do {
                try channel.pipeline.syncOperations.addHTTPClientHandlers(
                    leftOverBytesStrategy: configuration.leftoverBytesStrategy,
                    withClientUpgrade: upgradeConfig
                )

                if !supportedExtensions.isEmpty {
                    let clientUpgradeHandler = try channel.pipeline.syncOperations.handler(
                        type: NIOHTTPClientUpgradeHandler.self
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        WebSocketExtensionNegotiationResponseHandler(supportedExtensions: supportedExtensions),
                        position: .before(clientUpgradeHandler)
                    )
                }

                try channel.pipeline.syncOperations.addHandler(httpUpgradeHandler)
                return channel.closeFuture
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
    }

    /// Shutdown the WebSocket client.
    /// - Parameter callback: callback function that will be invoked when an error occurred during shutdown
    public func shutdown(_ callback: @escaping (Error?) -> Void) {
        let (exchanged, _) = self.isShutdown.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )

        if exchanged {
            self.eventloopGroup.shutdownGracefully(callback)
        } else {
            logger.info("WebSocket client already shutdown")
        }
    }

    private func makeHTTPRequestHeader(
        uri: String,
        host: String,
        port: Int,
        headers: [String: String]
    ) -> HTTPRequestHead {
        var httpHeaders = HTTPHeaders()
        httpHeaders.add(name: "Host", value: "\(host):\(port)")
        for (key, val) in headers {
            httpHeaders.add(name: key, value: val)
        }
        // TODO: need to support connect over proxy

        return HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: uri,
            headers: httpHeaders
        )
    }
}

extension WebSocketClient {
    private func makeBootstrapAndConnect(
        with configuration: LCLWebSocket.Configuration,
        resolvedAddress: SocketAddress,
        channelInitializer: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {

        func makeClientBootstrap() -> EventLoopFuture<Channel> {
            ClientBootstrap(group: self.eventloopGroup)
                .channelOption(
                    .socketOption(.so_reuseaddr),
                    value: SocketOptionValue(configuration.socketReuseAddress ? 1 : 0)
                )
                .channelOption(
                    .tcpOption(.tcp_nodelay),
                    value: SocketOptionValue(configuration.socketTcpNoDelay ? 1 : 0)
                )
                .channelOption(.socketOption(.so_sndbuf), value: configuration.socketSendBufferSize)
                .channelOption(.socketOption(.so_rcvbuf), value: configuration.socketReceiveBufferSize)
                .connectTimeout(configuration.connectionTimeout)
                .channelInitializer(channelInitializer)
                .connect(to: resolvedAddress)
        }

        #if canImport(Network)
        func makeNIOTSConnectionBootstrap() -> EventLoopFuture<Channel> {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.connectionTimeout = Int(configuration.connectionTimeout.seconds)
            tcpOptions.noDelay = configuration.socketTcpNoDelay

            return NIOTSConnectionBootstrap(group: self.eventloopGroup)
                .tcpOptions(tcpOptions)
                .channelOption(
                    .socketOption(.so_reuseaddr),
                    value: SocketOptionValue(configuration.socketReuseAddress ? 1 : 0)
                )
                .channelInitializer(channelInitializer)
                .connect(to: resolvedAddress)
        }
        #endif

        #if canImport(Network)
        if self.isMultiThreadedEventloop {
            return makeClientBootstrap()
        } else {
            return makeNIOTSConnectionBootstrap()
        }
        #else
        return makeClientBootstrap()
        #endif
    }

    private func makeChannelInitializer(
        configuration: LCLWebSocket.Configuration,
        resolvedAddress: SocketAddress,
        scheme: WebSocketScheme,
        host: String
    ) -> ChannelInitializer {
        @Sendable
        func makeChannelInitializer(_ channel: Channel) -> EventLoopFuture<Void> {
            if scheme.enableTLS {
                // enale TLS
                let tlsConfig = configuration.tlsConfiguration ?? scheme.defaultTLSConfig!
                guard let sslContext = try? NIOSSLContext(configuration: tlsConfig) else {

                    return channel.eventLoop.makeFailedFuture(LCLWebSocketError.tlsInitializationFailed)
                }

                do {
                    let sslClientHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    try channel.pipeline.syncOperations.addHandlers(sslClientHandler)
                } catch let error as NIOSSLExtraError where error == .invalidSNIHostname {
                    do {
                        let sslClientHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
                        try channel.pipeline.syncOperations.addHandlers(sslClientHandler)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

            if let deviceName = configuration.deviceName,
                let device = findDevice(with: deviceName, protocol: resolvedAddress.protocol)
            {
                // bind to selected device, if any
                logger.debug("deviceName \(deviceName), device \(device)")
                return bindTo(device, on: channel)
            }

            return channel.eventLoop.makeSucceededVoidFuture()
        }

        return makeChannelInitializer
    }
}

#if !canImport(Darwin) || swift(>=5.10)
extension WebSocketClient {

    /// Connect the WebSocket client to the given endpoint. The WebSocket client is configured using the provied configuration.
    /// While making the connection, the WebSocket client will be adding the addtional `headers`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoin to connect to in String format.
    ///   - headers: The additional headers that will be added to the HTTP Upgrade request, excluding WebSocket extension headers.
    ///   - configuration: The configuration that will be used to configure the WebSocket client.
    ///   - supportedExtensions: The WebSocket extensions that this client would like to negotiated with the server.
    /// - Returns: An `EventLoopFuture` that will be resolved once the connection is closed.
    ///
    /// - Note: this method is functionally the same as `connect(to:headers:configuration:)`. But this method relies on
    /// infrastructures that are available on Swift >= 5.10.
    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, *)
    public func typedConnect(
        to endpoint: String,
        headers: [String: String] = [:],
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption] = []
    ) -> EventLoopFuture<Void> {
        guard let urlComponents = URLComponents(string: endpoint) else {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        return self.typedConnect(
            to: urlComponents,
            headers: headers,
            configuration: configuration,
            supportedExtensions: supportedExtensions
        )
    }

    /// Connect the WebSocket client to the given endpoint. The WebSocket client is configured using the provied configuration.
    /// While making the connection, the WebSocket client will be adding the addtional `headers`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoin to connect to in `URL` format.
    ///   - headers: The additional headers that will be added to the HTTP Upgrade request, excluding WebSocket extension headers.
    ///   - configuration: The configuration that will be used to configure the WebSocket client.
    ///   - supportedExtensions: The WebSocket extensions that this client would like to negotiated with the server.
    /// - Returns: An `EventLoopFuture` that will be resolved once the connection is closed.
    ///
    /// - Note: this method is functionally the same as `connect(to:headers:configuration:)`. But this method relies on
    /// infrastructures that are available on Swift >= 5.10.
    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, *)
    public func typedConnect(
        to url: URL,
        headers: [String: String] = [:],
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption] = []
    ) -> EventLoopFuture<Void> {
        guard let urlComponents = URLComponents.init(url: url, resolvingAgainstBaseURL: false) else {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        return self.typedConnect(
            to: urlComponents,
            headers: headers,
            configuration: configuration,
            supportedExtensions: supportedExtensions
        )
    }

    /// Connect the WebSocket client to the given endpoint. The WebSocket client is configured using the provied configuration.
    /// While making the connection, the WebSocket client will be adding the addtional `headers`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoin to connect to.
    ///   - headers: The additional headers that will be added to the HTTP Upgrade request, excluding WebSocket extension headers..
    ///   - configuration: The configuration that will be used to configure the WebSocket client.
    ///   - supportedExtensions: The WebSocket extensions that this client would like to negotiated with the server.
    /// - Returns: An `EventLoopFuture` that will be resolved once the connection is closed.
    ///
    /// - Note: this method is functionally the same as `connect(to:headers:configuration:)`. But this method relies on
    /// infrastructures that are available on Swift >= 5.10.
    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, *)
    public func typedConnect(
        to endpoint: URLComponents,
        headers: [String: String],
        configuration: LCLWebSocket.Configuration,
        supportedExtensions: [any WebSocketExtensionOption]
    ) -> EventLoopFuture<Void> {
        guard let s = endpoint.scheme, let scheme = WebSocketScheme(rawValue: s) else {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        guard let host = endpoint.host else {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        let port = endpoint.port ?? scheme.defaultPort
        let path = endpoint.path.isEmpty ? "/" : endpoint.path
        let query = endpoint.query ?? ""
        let uri = path + (query.isEmpty ? "" : "?" + query)

        logger.debug("host: \(host) port: \(port) uri: \(uri)")

        let resolvedAddress: SocketAddress
        do {
            resolvedAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
        } catch {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        let upgradeResult = makeBootstrapAndConnect(
            with: configuration,
            resolvedAddress: resolvedAddress,
            channelInitializer: makeChannelInitializer(
                configuration: configuration,
                resolvedAddress: resolvedAddress,
                scheme: scheme,
                host: host
            )
        ).flatMap { channel in
            // make upgrade request
            let upgrader = NIOTypedWebSocketClientUpgrader<WebSocketUpgradeResult>(
                maxFrameSize: configuration.maxFrameSize,
                enableAutomaticErrorHandling: false
            ) { channel, httpResponse in
                // TODO: probably need to decode the response from server to populate for more fields like extension
                channel.eventLoop.makeCompletedFuture {
                    WebSocketUpgradeResult.websocket(channel)
                }
            }

            let httpRequestHead = self.makeHTTPRequestHeader(uri: uri, host: host, port: port, headers: headers)

            let upgradeConfig = NIOTypedHTTPClientUpgradeConfiguration(
                upgradeRequestHead: httpRequestHead,
                upgraders: [upgrader]
            ) { channel in
                logger.debug("not upgraded")
                return channel.eventLoop.makeCompletedFuture { .notUpgraded(nil) }
            }

            do {
                var httpClientPipelineConfiguration = NIOUpgradableHTTPClientPipelineConfiguration(
                    upgradeConfiguration: upgradeConfig
                )
                httpClientPipelineConfiguration.leftOverBytesStrategy = configuration.leftoverBytesStrategy

                return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: httpClientPipelineConfiguration
                ).flatMapThrowing { upgradeResult in
                    if !supportedExtensions.isEmpty {
                        let clientUpgradeHandler = try channel.pipeline.syncOperations.handler(
                            type: NIOHTTPClientUpgradeHandler.self
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            WebSocketExtensionNegotiationResponseHandler(supportedExtensions: supportedExtensions),
                            position: .before(clientUpgradeHandler)
                        )
                    }
                    return upgradeResult
                }
            } catch {
                return channel.eventLoop.makeCompletedFuture { .notUpgraded(error) }
            }
        }

        return upgradeResult.flatMap { upgradeResult in
            switch upgradeResult {
            case .notUpgraded(let error):
                if let error = error {
                    return self.eventloopGroup.any().makeFailedFuture(error)
                } else {
                    return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.notUpgraded)
                }
            case .websocket(let channel):
                let acceptedExtension: [any WebSocketExtensionOption]
                if supportedExtensions.isEmpty {
                    acceptedExtension = []
                } else {
                    do {
                        let extensionHandler = try channel.pipeline.syncOperations.handler(
                            type: WebSocketExtensionNegotiationResponseHandler.self
                        )
                        acceptedExtension = extensionHandler.acceptedExtensions

                        channel.pipeline.syncOperations.removeHandler(extensionHandler, promise: nil)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                let websocketConnectionInfo = WebSocket.ConnectionInfo(url: endpoint)
                let websocket = WebSocket(
                    channel: channel,
                    type: .client,
                    configuration: configuration,
                    connectionInfo: websocketConnectionInfo
                )
                websocket.onPing(self._onPing)
                websocket.onPong(self._onPong)
                websocket.onText(self._onText)
                websocket.onBinary(self._onBinary)
                websocket.onError(self._onError)
                websocket.onClosing(self._onClosing)
                websocket.onClosed(self._onClosed)

                do {
                    try channel.syncOptions?.setOption(
                        .writeBufferWaterMark,
                        value: .init(
                            low: configuration.writeBufferWaterMarkLow,
                            high: configuration.writeBufferWaterMarkHigh
                        )
                    )

                    try channel.pipeline.syncOperations.addHandler(
                        WebSocketHandler(
                            websocket: websocket,
                            configuration: configuration,
                            extensions: acceptedExtension
                        )
                    )
                    self._onOpen?(websocket)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                return channel.closeFuture
            }
        }
    }
}
#endif

private final class HTTPUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let httpRequestHead: HTTPRequestHead

    init(httpRequest: HTTPRequestHead) {
        self.httpRequestHead = httpRequest
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.debug("sent HTTP upgrade request \(self.httpRequestHead)")
        context.write(self.wrapOutboundOut(.head(self.httpRequestHead)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
