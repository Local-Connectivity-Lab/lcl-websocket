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
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import NIOTransportServices
#endif

#if canImport(Network)
import Network
#endif

public struct WebSocketClient: Sendable, LCLWebSocketListenable {

    private enum WebSocketUpgradeResult {
        case websocket(Channel)
        case notUpgraded(Error?)
    }

    public let eventloopGroup: any EventLoopGroup

    // MARK: callbacks
    private var _onOpen: (@Sendable (WebSocket) -> Void)?
    private var _onPing: (@Sendable (ByteBuffer) -> Void)?
    private var _onPong: (@Sendable (ByteBuffer) -> Void)?
    private var _onText: (@Sendable (String) -> Void)?
    private var _onBinary: (@Sendable (ByteBuffer) -> Void)?
    private var _onError: (@Sendable (Error) -> Void)?

    public init(on eventloopGroup: any EventLoopGroup) {
        self.eventloopGroup = eventloopGroup
    }

    public mutating func onOpen(_ callback: (@Sendable (WebSocket) -> Void)?) {
        self._onOpen = callback
    }

    public mutating func onPing(_ callback: (@Sendable (ByteBuffer) -> Void)?) {
        self._onPing = callback
    }

    public mutating func onPong(_ callback: (@Sendable (ByteBuffer) -> Void)?) {
        self._onPong = callback
    }

    public mutating func onText(_ callback: (@Sendable (String) -> Void)?) {
        self._onText = callback
    }

    public mutating func onBinary(_ callback: (@Sendable (ByteBuffer) -> Void)?) {
        self._onBinary = callback
    }

    @available(macOS 13, *)
    public func connect(
        to endpoint: URL,
        headers: [String: String] = [:],
        config: LCLWebSocket.Configuration
    ) -> EventLoopFuture<Void> {
        guard let urlComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return self.eventloopGroup.next().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        return self.connect(to: urlComponents, headers: headers, configuration: config)
    }

    @available(macOS 13, *)
    public func connect(
        to endpoint: String,
        headers: [String: String] = [:],
        config: LCLWebSocket.Configuration
    ) -> EventLoopFuture<Void> {
        guard let urlComponents = URLComponents(string: endpoint) else {
            return self.eventloopGroup.next().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        return self.connect(to: urlComponents, headers: headers, configuration: config)
    }

    @available(macOS 13, *)
    public func connect(
        to endpoint: URLComponents,
        headers: [String: String] = [:],
        configuration: LCLWebSocket.Configuration
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

        let resolvedAddress: SocketAddress
        do {
            resolvedAddress = try SocketAddress.makeAddressResolvingHost(host, port: port)
        } catch {
            return self.eventloopGroup.any().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        let upgradeResult = ClientBootstrap(group: self.eventloopGroup)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(configuration.connectionTimeout)
            .channelInitializer { channel in
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

                // enable TLS
                if scheme.enableTLS {
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

                return channel.eventLoop.makeSucceededVoidFuture()
            }.connect(to: resolvedAddress).flatMap { channel in
                // make upgrade request
                let upgrader = NIOTypedWebSocketClientUpgrader<WebSocketUpgradeResult>(
                    maxFrameSize: configuration.maxFrameSize
                ) { channel, _ in
                    // TODO: probably need to decode the response from server to populate for more fields like extension
                    channel.eventLoop.makeCompletedFuture {
                        WebSocketUpgradeResult.websocket(channel)
                    }
                }

                var httpHeaders = HTTPHeaders()
                httpHeaders.add(name: "Host", value: "\(host):\(port)")
                for (key, val) in headers {
                    httpHeaders.add(name: key, value: val)
                }
                // TODO: need to handle extension
                // TODO: need to support connect over proxy

                let httpRequestHead = HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: uri,
                    headers: httpHeaders
                )

                let upgradeConfig = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: httpRequestHead,
                    upgraders: [upgrader]
                ) { channel in
                    channel.eventLoop.makeCompletedFuture { .notUpgraded(nil) }
                }

                do {
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                        configuration: .init(upgradeConfiguration: upgradeConfig)
                    )
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

                do {
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
                    print(channel.pipeline.debugDescription)
                    self._onOpen?(websocket)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        }
    }

    public func shutdown() {
        self.eventloopGroup.shutdownGracefully { error in
            if let error = error {
                logger.error("Error shutting down WebSocketClient: \(error)")
            }
        }
    }
}
